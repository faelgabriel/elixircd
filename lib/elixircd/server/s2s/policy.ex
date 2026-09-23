defmodule ElixIRCd.Server.S2S.Policy do
  @moduledoc """
  Non-secret services policy projections and revisioned cache algebra.

  The authority's private tables remain the source of truth. This module only
  accepts explicit public projections and applies complete revision batches
  atomically at a receiving node.
  """

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.JSON

  @account_settings ~w(enforce enforce_time kill hide_status hide_usermask hide_quit never_op no_greet quiet_chg secure)
  @channel_settings ~w(entrymsg keeptopic persistent_topic opnotice peace private restricted secure fantasy guard topiclock mlock)
  @entities ~w(account nick channel)
  @max_object_bytes 32_768
  @max_aliases 512
  @max_access 512

  @type state :: %{
          epoch: Identity.id(),
          revision: non_neg_integer(),
          objects: %{optional({String.t(), String.t()}) => map()},
          ready?: boolean()
        }

  @doc "Creates an empty policy cache for one authority epoch."
  @spec new(keyword()) :: state()
  def new(options \\ []) do
    %{
      epoch: Keyword.get(options, :epoch, Identity.nonce()),
      revision: Keyword.get(options, :revision, 0),
      objects: Keyword.get(options, :objects, %{}),
      ready?: Keyword.get(options, :ready?, false)
    }
  end

  @doc "Projects only the public fields allowed for an account object."
  @spec project_account(map()) :: {:ok, map()} | {:error, term()}
  def project_account(source) when is_map(source) do
    settings = project_settings(source_value(source, :settings, %{}), @account_settings)
    aliases = source_value(source, :aliases, []) |> List.wrap()

    value = %{
      "account_id" => source_value(source, :account_id),
      "canonical_name" => source_value(source, :canonical_name),
      "display_name" => source_value(source, :display_name),
      "auth_epoch" => source_value(source, :auth_epoch),
      "verified" => source_value(source, :verified),
      "aliases" => aliases,
      "settings" => settings
    }

    validate_object("account", source_value(source, :account_id), value, aliases, @max_aliases)
  end

  def project_account(_source), do: {:error, :invalid_account_projection}

  @doc "Projects one public nickname ownership record."
  @spec project_nick(map()) :: {:ok, map()} | {:error, term()}
  def project_nick(source) when is_map(source) do
    value = %{
      "nickname" => source_value(source, :nickname),
      "account_id" => source_value(source, :account_id),
      "reserved_until_ms" => source_value(source, :reserved_until_ms, 0)
    }

    validate_object("nick", normalize_key(source_value(source, :nickname)), value)
  end

  def project_nick(_source), do: {:error, :invalid_nick_projection}

  @doc "Projects a registered global channel without private ACL or memo data."
  @spec project_channel(map()) :: {:ok, map()} | {:error, term()}
  def project_channel(source) when is_map(source) do
    settings = project_settings(source_value(source, :settings, %{}), @channel_settings)
    access = source_value(source, :access, []) |> List.wrap()

    value = %{
      "name" => source_value(source, :name),
      "founder_account_id" => source_value(source, :founder_account_id),
      "successor_account_id" => source_value(source, :successor_account_id),
      "access" => access,
      "settings" => settings,
      "saved_topic" => source_value(source, :saved_topic)
    }

    validate_object("channel", normalize_key(source_value(source, :name)), value, access, @max_access)
  end

  def project_channel(_source), do: {:error, :invalid_channel_projection}

  @doc "Builds the authority's public image from the existing service records."
  @spec from_sources(Identity.id(), [map()], [map()], [map()], [map()], keyword()) ::
          {:ok, state()} | {:error, term()}
  def from_sources(epoch, registered_nicks, registered_channels, access_entries, nick_accesses, options \\ [])

  def from_sources(epoch, registered_nicks, registered_channels, access_entries, nick_accesses, options)
      when is_binary(epoch) and is_list(registered_nicks) and is_list(registered_channels) and
             is_list(access_entries) and is_list(nick_accesses) do
    account_records = group_accounts(registered_nicks)

    account_ids =
      Map.new(account_records, fn {account_key, records} -> {account_key, account_id(account_key, records)} end)

    with {:ok, account_objects} <- project_accounts(account_records, account_ids),
         {:ok, nick_objects} <- project_nicks(registered_nicks, account_ids),
         {:ok, channel_objects} <- project_channels(registered_channels, access_entries, account_ids) do
      objects = account_objects ++ nick_objects ++ channel_objects
      revision = Keyword.get(options, :revision, if(objects == [], do: 0, else: 1))

      with true <- Identity.valid_uint?(revision),
           {:ok, object_map} <- object_map(objects),
           :ok <- validate_object_count(object_map) do
        {:ok, new(epoch: epoch, revision: revision, objects: object_map, ready?: true)}
      else
        false -> {:error, :invalid_policy_revision}
        {:error, _} = error -> error
      end
    end
  end

  def from_sources(_epoch, _registered_nicks, _registered_channels, _access_entries, _nick_accesses, _options),
    do: {:error, :invalid_policy_sources}

  @doc "Returns the bounded public changes between two projected policy images."
  @spec diff(state(), state()) :: [map()]
  def diff(%{objects: previous}, %{objects: current}) when is_map(previous) and is_map(current) do
    keys = MapSet.union(MapSet.new(Map.keys(previous)), MapSet.new(Map.keys(current)))

    keys
    |> Enum.sort()
    |> Enum.flat_map(fn {entity, key} ->
      case {previous[{entity, key}], current[{entity, key}]} do
        {old, new} when old == new -> []
        {_old, nil} -> [%{"entity" => entity, "key" => key, "value" => nil}]
        {_old, new} -> [%{"entity" => entity, "key" => key, "value" => new}]
      end
    end)
  end

  def diff(_previous, _current), do: []

  @doc "Applies one complete contiguous policy batch atomically."
  @spec apply_change(state(), Identity.id(), non_neg_integer(), list() | nil) ::
          {:ok, state(), :applied | :invalidated | :unchanged} | {:error, term()}
  def apply_change(state, epoch, revision, changes)
      when is_map(state) and is_integer(revision) and revision >= 0 do
    cond do
      epoch != state.epoch -> {:error, :policy_epoch_mismatch}
      revision < state.revision -> {:ok, state, :unchanged}
      revision == state.revision -> same_revision(state, changes)
      revision != state.revision + 1 -> {:error, {:policy_revision_gap, state.revision + 1, revision}}
      changes == nil -> {:ok, %{state | revision: revision, ready?: false}, :invalidated}
      not is_list(changes) or length(changes) > 256 -> {:error, :invalid_policy_batch}
      true -> apply_batch(state, revision, changes)
    end
  end

  @doc "Validates one public policy object without exposing private service data."
  @spec validate_public_object(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def validate_public_object(entity, key, value) when entity in @entities and is_binary(key) do
    case validate_object(entity, key, value) do
      {:ok, _validated} -> :ok
      {:error, _} = error -> error
    end
  end

  def validate_public_object(_entity, _key, _value), do: {:error, :invalid_policy_object}

  @doc "Marks a complete image as ready and removes objects absent from it."
  @spec install_image(state(), Identity.id(), non_neg_integer(), list()) ::
          {:ok, state()} | {:error, term()}
  def install_image(state, epoch, revision, objects) when is_list(objects) do
    with true <- epoch == state.epoch,
         true <- Identity.valid_uint?(revision),
         true <- revision >= state.revision,
         true <- Enum.all?(objects, &valid_image_row?/1),
         true <- length(objects) == length(Enum.uniq_by(objects, &{&1["entity"], &1["key"]})),
         {:ok, object_map} <- object_map(objects),
         :ok <- validate_object_count(object_map) do
      cond do
        revision == state.revision and state.ready? and object_map != state.objects ->
          {:error, :policy_revision_conflict}

        true ->
          {:ok, %{state | epoch: epoch, revision: revision, objects: object_map, ready?: true}}
      end
    else
      false -> {:error, :invalid_policy_image}
      {:error, _} = error -> error
    end
  end

  @doc "Returns whether an account-dependent operation may use this cache."
  @spec grant_ready?(state()) :: boolean()
  def grant_ready?(%{ready?: true, epoch: epoch}) do
    Identity.valid_id?(epoch)
  end

  def grant_ready?(_state), do: false

  @doc "Reads a projected policy object by its finite entity/key pair."
  @spec get(state(), String.t(), String.t()) :: {:ok, map()} | :not_found
  def get(%{objects: objects}, entity, key) when entity in @entities do
    case Map.fetch(objects, {entity, key}) do
      {:ok, value} -> {:ok, value}
      :error -> :not_found
    end
  end

  def get(_state, _entity, _key), do: :not_found

  @doc "Builds bounded policy image payloads for a snapshot reply."
  @spec image_payloads(state(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def image_payloads(%{epoch: epoch, revision: revision, objects: objects}, max_rows)
      when is_integer(max_rows) and max_rows > 0 do
    entries =
      objects
      |> Enum.sort_by(fn {{entity, key}, _value} -> {entity, key} end)
      |> Enum.map(fn {{entity, key}, value} -> %{"entity" => entity, "key" => key, "value" => value} end)

    if Enum.any?(entries, &(byte_size(JSON.encode(&1)) > @max_object_bytes)),
      do: {:error, :policy_object_too_large},
      else:
        {:ok,
         [
           %{
             "snapshot" => "policy",
             "phase" => "begin",
             "epoch" => epoch,
             "revision" => revision,
             "objects" => length(entries)
           }
           | Enum.map(Enum.chunk_every(entries, max_rows), &%{"snapshot" => "policy", "phase" => "rows", "rows" => &1})
         ] ++
           [
             %{
               "snapshot" => "policy",
               "phase" => "end",
               "epoch" => epoch,
               "revision" => revision,
               "objects" => length(entries)
             }
           ]}
  end

  def image_payloads(_state, _max_rows), do: {:error, :invalid_policy_image_limit}

  @doc "Starts a bounded complete-image receiver staging context."
  @spec new_image_staging(Identity.id(), keyword()) :: map()
  def new_image_staging(epoch, options \\ []) do
    %{
      epoch: epoch,
      revision: nil,
      expected_objects: nil,
      rows: [],
      keys: MapSet.new(),
      bytes: 0,
      max_objects: Keyword.get(options, :max_objects, 65_536),
      max_bytes: Keyword.get(options, :max_bytes, 128 * 1_048_576)
    }
  end

  @doc "Stages one policy image payload without changing the active cache."
  @spec stage_image(map(), map()) :: {:ok, map()} | {:error, term()}
  def stage_image(
        staging,
        %{"snapshot" => "policy", "phase" => "begin", "epoch" => epoch, "revision" => revision, "objects" => count} =
          payload
      ) do
    if Map.keys(payload) |> Enum.sort() == ~w(epoch objects phase revision snapshot) and
         epoch == staging.epoch and Identity.valid_uint?(revision) and Identity.valid_uint?(count) and
         staging.expected_objects == nil,
       do: {:ok, %{staging | revision: revision, expected_objects: count}},
       else: {:error, :invalid_policy_image_begin}
  end

  def stage_image(
        %{rows: existing, keys: keys} = staging,
        %{"snapshot" => "policy", "phase" => "rows", "rows" => rows} = payload
      )
      when is_list(rows) do
    body_bytes = byte_size(JSON.encode(payload))

    with true <- Map.keys(payload) |> Enum.sort() == ~w(rows phase snapshot),
         true <- staging.expected_objects != nil,
         true <- length(rows) <= 256,
         true <- staging.bytes + body_bytes <= staging.max_bytes,
         true <- length(existing) + length(rows) <= staging.max_objects,
         {:ok, validated} <- validate_image_rows(rows),
         row_keys <- Enum.map(validated, &{&1["entity"], &1["key"]}),
         true <- Enum.all?(row_keys, &(not MapSet.member?(keys, &1))) do
      {:ok,
       %{
         staging
         | rows: existing ++ validated,
           keys: Enum.reduce(row_keys, keys, &MapSet.put(&2, &1)),
           bytes: staging.bytes + body_bytes
       }}
    else
      false -> {:error, :invalid_policy_image_rows}
      {:error, _} = error -> error
    end
  end

  def stage_image(
        %{epoch: expected_epoch, revision: expected_revision, expected_objects: expected, rows: rows} = staging,
        %{"snapshot" => "policy", "phase" => "end", "epoch" => epoch, "revision" => revision, "objects" => objects} =
          payload
      ) do
    if Map.keys(payload) |> Enum.sort() == ~w(epoch objects phase revision snapshot) and
         epoch == expected_epoch and revision == expected_revision and objects == expected and length(rows) == expected,
       do: {:ok, Map.put(staging, :complete?, true)},
       else: {:error, :invalid_policy_image_end}
  end

  def stage_image(_staging, _payload), do: {:error, :invalid_policy_image_phase}

  @doc "Installs a finished image atomically and clears deleted objects."
  @spec finish_image(state(), map()) :: {:ok, state()} | {:error, term()}
  def finish_image(state, %{complete?: true, epoch: epoch, revision: revision, rows: rows}) do
    install_image(state, epoch, revision, rows)
  end

  def finish_image(_state, _staging), do: {:error, :incomplete_policy_image}

  defp same_revision(state, nil), do: {:ok, %{state | ready?: false}, :invalidated}

  defp same_revision(state, changes) when is_list(changes) do
    case apply_changes(state.objects, changes) do
      {:ok, objects} when objects == state.objects -> {:ok, state, :unchanged}
      {:ok, _objects} -> {:error, :policy_revision_conflict}
      {:error, _} = error -> error
    end
  end

  defp same_revision(_state, _changes), do: {:error, :invalid_policy_batch}

  defp validate_image_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      %{"entity" => entity, "key" => key, "value" => value} = row, {:ok, acc} ->
        if Map.keys(row) |> Enum.sort() == ~w(entity key value) and validate_public_object(entity, key, value) == :ok,
          do: {:cont, {:ok, [row | acc]}},
          else: {:halt, {:error, :invalid_policy_image_object}}

      _row, _acc ->
        {:halt, {:error, :invalid_policy_image_object}}
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, _} = error -> error
    end
  end

  defp apply_batch(state, revision, changes) do
    with {:ok, objects} <- apply_changes(state.objects, changes) do
      {:ok, %{state | revision: revision, objects: objects, ready?: true}, :applied}
    end
  end

  defp apply_changes(objects, changes) do
    keys = Enum.map(changes, &change_key/1)

    cond do
      Enum.any?(keys, &is_nil/1) -> {:error, :invalid_policy_change}
      length(keys) != length(Enum.uniq(keys)) -> {:error, :duplicate_policy_change}
      true -> Enum.reduce_while(changes, {:ok, objects}, &apply_one/2)
    end
  end

  defp apply_one(change, {:ok, objects}) do
    case validate_change(change) do
      {:ok, {entity, key, value}} ->
        objects = if is_nil(value), do: Map.delete(objects, {entity, key}), else: Map.put(objects, {entity, key}, value)
        {:cont, {:ok, objects}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp change_key(%{"entity" => entity, "key" => key}), do: {entity, key}
  defp change_key(_change), do: nil

  defp validate_change(%{"entity" => entity, "key" => key, "value" => value} = change)
       when entity in @entities and is_binary(key) do
    if Map.keys(change) |> Enum.sort() == ~w(entity key value) do
      if is_nil(value) do
        if valid_object_key?(entity, key), do: {:ok, {entity, key, nil}}, else: {:error, :invalid_policy_change}
      else
        case validate_object(entity, key, value) do
          {:ok, validated} -> {:ok, {entity, key, validated}}
          {:error, _} = error -> error
        end
      end
    else
      {:error, :invalid_policy_change}
    end
  end

  defp validate_change(_change), do: {:error, :invalid_policy_change}

  defp object_map(objects) do
    Enum.reduce_while(objects, {:ok, %{}}, fn
      %{"entity" => entity, "key" => key, "value" => value}, {:ok, acc} ->
        case validate_object(entity, key, value) do
          {:ok, validated} -> {:cont, {:ok, Map.put(acc, {entity, key}, validated)}}
          {:error, _} = error -> {:halt, error}
        end

      _row, _acc ->
        {:halt, {:error, :invalid_policy_object}}
    end)
  end

  defp valid_image_row?(%{"entity" => entity, "key" => key, "value" => value}),
    do: is_binary(entity) and is_binary(key) and is_map(value)

  defp valid_image_row?(_row), do: false

  defp validate_object_count(objects),
    do: if(map_size(objects) <= 65_536, do: :ok, else: {:error, :policy_object_count})

  defp validate_object(entity, key, value, items \\ [], limit \\ @max_aliases)

  defp validate_object("account", key, value, aliases, limit) do
    allowed = ~w(account_id canonical_name display_name auth_epoch verified aliases settings)

    with true <- is_map(value),
         true <- is_binary(key) and Map.keys(value) |> Enum.sort() == Enum.sort(allowed),
         true <- value["account_id"] == key and Identity.valid_id?(value["account_id"]),
         true <- valid_name(value["canonical_name"]) and valid_name(value["display_name"]),
         true <- Identity.valid_positive?(value["auth_epoch"]),
         true <- is_boolean(value["verified"]),
         true <-
           is_list(value["aliases"]) and length(value["aliases"]) <= limit and
             length(Enum.uniq(value["aliases"])) == length(value["aliases"]) and
             Enum.all?(value["aliases"], &valid_name/1),
         true <- aliases == [] or value["aliases"] == aliases,
         :ok <- validate_account_settings(value["settings"]),
         :ok <- validate_object_budget(value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_account_policy}
    end
  end

  defp validate_object("nick", key, value, _items, _limit) do
    with true <- is_map(value),
         true <- is_binary(key) and Map.keys(value) |> Enum.sort() == ~w(account_id nickname reserved_until_ms),
         true <- valid_name(value["nickname"]) and normalize_key(value["nickname"]) == key,
         true <- is_nil(value["account_id"]) or Identity.valid_id?(value["account_id"]),
         true <- Identity.valid_uint?(value["reserved_until_ms"]) do
      {:ok, value}
    else
      _ -> {:error, :invalid_nick_policy}
    end
  end

  defp validate_object("channel", key, value, access, limit) do
    with true <- is_map(value),
         true <-
           is_binary(key) and
             Map.keys(value) |> Enum.sort() ==
               ~w(access founder_account_id name saved_topic settings successor_account_id),
         true <- valid_global_channel?(value["name"]) and normalize_key(value["name"]) == key,
         true <- is_nil(value["founder_account_id"]) or Identity.valid_id?(value["founder_account_id"]),
         true <- is_nil(value["successor_account_id"]) or Identity.valid_id?(value["successor_account_id"]),
         true <- is_list(value["access"]) and length(value["access"]) <= limit,
         true <- length(Enum.uniq(value["access"])) == length(value["access"]),
         :ok <- validate_access(value["access"]),
         true <- access == [] or access == value["access"],
         :ok <- validate_channel_settings(value["settings"]),
         :ok <- validate_saved_topic(value["saved_topic"]),
         :ok <- validate_object_budget(value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_channel_policy}
    end
  end

  defp validate_object(_entity, _key, _value, _items, _limit), do: {:error, :invalid_policy_entity}

  defp valid_object_key?("account", key), do: Identity.valid_id?(key)
  defp valid_object_key?("nick", key), do: valid_name(key) and normalize_key(key) == key
  defp valid_object_key?("channel", key), do: valid_global_channel?(key) and normalize_key(key) == key
  defp valid_object_key?(_entity, _key), do: false

  defp group_accounts(records) do
    records
    |> Enum.group_by(&source_value(&1, :account_name_key, source_value(&1, :account_name)))
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp project_accounts(account_records, account_ids) do
    account_records
    |> Enum.reduce_while({:ok, []}, fn {account_key, records}, {:ok, objects} ->
      records = Enum.sort_by(records, &{datetime_ms(source_value(&1, :created_at)), source_value(&1, :nickname, "")})
      primary = Enum.find(records, &(source_value(&1, :nickname_key) == account_key)) || hd(records)
      aliases = records |> Enum.map(&source_value(&1, :nickname, "")) |> Enum.uniq() |> Enum.sort()
      id = Map.fetch!(account_ids, account_key)
      settings = source_value(primary, :settings, %{})

      source = %{
        account_id: id,
        canonical_name: source_value(primary, :account_name, source_value(primary, :nickname, "")),
        display_name: source_value(settings, :display, nil) || source_value(primary, :account_name, ""),
        auth_epoch: auth_epoch(primary),
        verified: not is_nil(source_value(primary, :verified_at)),
        aliases: aliases,
        settings: settings
      }

      case project_account(source) do
        {:ok, value} -> {:cont, {:ok, [{"account", id, value} | objects]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> reverse_objects()
  end

  defp project_nicks(records, account_ids) do
    records
    |> Enum.sort_by(&source_value(&1, :nickname_key, source_value(&1, :nickname, "")))
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, objects} ->
      key = source_value(record, :nickname_key, source_value(record, :nickname, ""))
      account_key = source_value(record, :account_name_key, source_value(record, :account_name, ""))

      source = %{
        nickname: source_value(record, :nickname, key),
        account_id: Map.get(account_ids, account_key),
        reserved_until_ms: datetime_ms(source_value(record, :reserved_until))
      }

      case project_nick(source) do
        {:ok, value} -> {:cont, {:ok, [{"nick", key, value} | objects]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> reverse_objects()
  end

  defp project_channels(records, access_entries, account_ids) do
    access_by_channel = Enum.group_by(access_entries, &source_value(&1, :channel_name_key, ""))

    records
    |> Enum.sort_by(&source_value(&1, :name_key, source_value(&1, :name, "")))
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, objects} ->
      channel_key = source_value(record, :name_key, source_value(record, :name, ""))
      founder = source_value(record, :founder, "")
      successor = source_value(record, :successor)

      access =
        access_by_channel
        |> Map.get(channel_key, [])
        |> Enum.map(fn entry ->
          account_key = source_value(entry, :account_name_key, source_value(entry, :account_name, ""))
          [Map.get(account_ids, account_key), source_value(entry, :flags, "")]
        end)
        |> Enum.filter(fn [id, flags] -> Identity.valid_id?(id) and is_binary(flags) end)
        |> Enum.sort()

      topic = source_value(record, :topic)
      settings = source_value(record, :settings, %{})

      source = %{
        name: source_value(record, :name, channel_key),
        founder_account_id: Map.get(account_ids, normalize_key(founder)),
        successor_account_id: if(is_nil(successor), do: nil, else: Map.get(account_ids, normalize_key(successor))),
        access: access,
        settings: settings,
        saved_topic: saved_topic(topic, settings, record)
      }

      case project_channel(source) do
        {:ok, value} -> {:cont, {:ok, [{"channel", channel_key, value} | objects]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> reverse_objects()
  end

  defp reverse_objects({:ok, objects}), do: {:ok, Enum.reverse(objects) |> Enum.map(&object_row/1)}
  defp reverse_objects({:error, _} = error), do: error

  defp object_row({entity, key, value}), do: %{"entity" => entity, "key" => key, "value" => value}

  defp account_id(_account_key, records) do
    source_value(List.first(records), :account_id)
  end

  defp auth_epoch(record), do: source_value(record, :auth_epoch)

  defp datetime_ms(nil), do: 0
  defp datetime_ms(%DateTime{} = value), do: max(DateTime.to_unix(value, :millisecond), 0)
  defp datetime_ms(value) when is_integer(value), do: max(value, 0)
  defp datetime_ms(_value), do: 0

  defp saved_topic(%{text: text, setter: setter, set_at: set_at}, _settings, _record),
    do: %{"text" => text, "setter" => setter, "set_ms" => datetime_ms(set_at)}

  defp saved_topic(%{"text" => text, "setter" => setter, "set_ms" => set_ms}, _settings, _record),
    do: %{"text" => text, "setter" => setter, "set_ms" => set_ms}

  defp saved_topic(_topic, settings, record) do
    case source_value(settings, :persistent_topic) do
      text when is_binary(text) ->
        %{
          "text" => text,
          "setter" => source_value(record, :registered_by, "ChanServ"),
          "set_ms" => datetime_ms(source_value(record, :created_at))
        }

      _ ->
        nil
    end
  end

  defp normalize_key(value) when is_binary(value), do: String.downcase(value)
  defp normalize_key(_value), do: ""

  defp project_settings(source, keys) when is_map(source) do
    Enum.reduce(keys, %{}, fn key, acc ->
      Map.put(acc, key, setting_value(source, key))
    end)
  end

  defp project_settings(_source, _keys), do: %{}

  defp setting_value(source, "kill") do
    case source_value(source, :kill, setting_default("kill")) do
      value when is_atom(value) -> Atom.to_string(value)
      value -> value
    end
  end

  defp setting_value(source, key), do: source_value(source, setting_key(key), setting_default(key))

  defp validate_account_settings(settings) when is_map(settings) do
    allowed = @account_settings
    keys = Map.keys(settings)

    if Enum.sort(keys) == Enum.sort(allowed) and
         is_boolean(settings["enforce"]) and Identity.valid_uint?(settings["enforce_time"]) and
         settings["kill"] in ~w(on quick immed off) and
         Enum.all?(Map.drop(settings, ["enforce", "enforce_time", "kill"]), &is_boolean(elem(&1, 1))),
       do: :ok,
       else: {:error, :invalid_account_settings}
  end

  defp validate_account_settings(_settings), do: {:error, :invalid_account_settings}

  defp validate_channel_settings(settings) when is_map(settings) do
    if Enum.sort(Map.keys(settings)) == Enum.sort(@channel_settings) and
         (is_nil(settings["entrymsg"]) or valid_policy_text?(settings["entrymsg"], 4_096)) and
         (is_nil(settings["persistent_topic"]) or valid_policy_text?(settings["persistent_topic"], 4_096)) and
         (is_nil(settings["mlock"]) or valid_policy_text?(settings["mlock"], 4_096)) and
         Enum.all?(Map.drop(settings, ["entrymsg", "persistent_topic", "mlock"]), &is_boolean(elem(&1, 1))) do
      :ok
    else
      {:error, :invalid_channel_settings}
    end
  end

  defp validate_channel_settings(_settings), do: {:error, :invalid_channel_settings}

  defp validate_saved_topic(nil), do: :ok

  defp validate_saved_topic(%{"text" => text, "setter" => setter, "set_ms" => set_ms} = value)
       when map_size(value) == 3 do
    if valid_policy_text?(text, 4_096) and valid_policy_text?(setter, 512) and Identity.valid_uint?(set_ms),
      do: :ok,
      else: {:error, :invalid_saved_topic}
  end

  defp validate_saved_topic(_value), do: {:error, :invalid_saved_topic}

  defp validate_access(access) do
    if Enum.all?(access, fn
         [account_id, flags] when is_binary(account_id) and is_binary(flags) ->
           byte_size(flags) <= 5 and Identity.valid_id?(account_id) and
             String.graphemes(flags) |> Enum.uniq() |> Enum.all?(&(&1 in ~w(V A F S T)))

         _ ->
           false
       end),
       do: :ok,
       else: {:error, :invalid_access}
  end

  defp validate_object_budget(value) do
    body = JSON.encode(value)

    with true <- byte_size(body) <= @max_object_bytes,
         :ok <- JSON.scan(body, max_depth: 16, max_values: 1_024) do
      :ok
    else
      _ -> {:error, :policy_object_budget}
    end
  end

  defp valid_name(value),
    do: valid_policy_text?(value, 255) and byte_size(value) > 0

  defp valid_global_channel?(value), do: valid_name(value) and String.starts_with?(value, "#")

  defp valid_policy_text?(value, max)
       when is_binary(value) and is_integer(max) and max >= 0,
       do: byte_size(value) <= max and String.valid?(value) and safe_text?(value)

  defp valid_policy_text?(_value, _max), do: false

  defp safe_text?(value),
    do:
      :binary.match(value, <<0>>) == :nomatch and :binary.match(value, "\r") == :nomatch and
        :binary.match(value, "\n") == :nomatch

  defp source_value(source, key, default \\ nil) when is_map(source),
    do: Map.get(source, key, Map.get(source, Atom.to_string(key), default))

  defp setting_key("enforce"), do: :enforce
  defp setting_key("enforce_time"), do: :enforce_time
  defp setting_key("kill"), do: :kill
  defp setting_key("hide_status"), do: :hide_status
  defp setting_key("hide_usermask"), do: :hide_usermask
  defp setting_key("hide_quit"), do: :hide_quit
  defp setting_key("never_op"), do: :never_op
  defp setting_key("no_greet"), do: :no_greet
  defp setting_key("quiet_chg"), do: :quiet_chg
  defp setting_key("secure"), do: :secure
  defp setting_key("entrymsg"), do: :entrymsg
  defp setting_key("keeptopic"), do: :keeptopic
  defp setting_key("persistent_topic"), do: :persistent_topic
  defp setting_key("opnotice"), do: :opnotice
  defp setting_key("peace"), do: :peace
  defp setting_key("private"), do: :private
  defp setting_key("restricted"), do: :restricted
  defp setting_key("fantasy"), do: :fantasy
  defp setting_key("guard"), do: :guard
  defp setting_key("topiclock"), do: :topiclock
  defp setting_key("mlock"), do: :mlock

  defp setting_default("enforce_time"), do: 0
  defp setting_default("kill"), do: "off"
  defp setting_default(key) when key in ["entrymsg", "persistent_topic", "mlock"], do: nil
  defp setting_default(_key), do: false
end
