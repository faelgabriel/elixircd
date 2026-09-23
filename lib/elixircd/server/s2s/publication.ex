defmodule ElixIRCd.Server.S2S.Publication do
  @moduledoc """
  Collects one post-commit publication intent from the existing C2S repositories.

  Repository code only records immutable local facts while a transaction is
  open. Projection, database reads needed for a complete membership image and
  the manager call all happen in the output drain after commit.
  """

  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelExcepts
  alias ElixIRCd.Repositories.ChannelInvexes
  alias ElixIRCd.Repositories.ChannelListTombstones
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.Output
  alias ElixIRCd.Server.S2S.Projection
  alias ElixIRCd.Server.S2S.Schema
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.Channel.Topic
  alias ElixIRCd.Tables.User

  @doc "Queues a post-commit refresh of the authority's public policy image."
  @spec policy_changed() :: :ok
  def policy_changed, do: enqueue(%{kind: :s2s_policy_changed})

  @doc "Suppresses repository refresh intents while an endpoint owns the explicit policy row."
  @spec with_policy_refresh_suppressed((-> result)) :: result when result: var
  def with_policy_refresh_suppressed(fun) when is_function(fun, 0) do
    key = {__MODULE__, :suppress_policy_refresh}
    previous = Process.get(key)
    Process.put(key, true)

    try do
      fun.()
    after
      if is_nil(previous), do: Process.delete(key), else: Process.put(key, previous)
    end
  end

  @doc "Queues a complete public user projection after a successful local write."
  @spec user_changed(User.t()) :: :ok
  def user_changed(%User{} = user), do: enqueue(%{kind: :s2s_user_put, user: user_snapshot(user)})

  @doc "Queues the owner quit row before the local user record disappears."
  @spec user_deleted(User.t(), String.t()) :: :ok
  def user_deleted(%User{} = user, reason),
    do: enqueue(%{kind: :s2s_user_quit, user: user_snapshot(user), reason: reason})

  @doc "Queues a complete membership replacement for one UID."
  @spec memberships_changed(String.t()) :: :ok
  @spec memberships_changed(String.t(), term()) :: :ok
  def memberships_changed(uid, cause \\ nil)

  def memberships_changed(uid, cause) when is_binary(uid),
    do: enqueue(%{kind: :s2s_memberships, uid: uid, cause: cause})

  def memberships_changed(_uid, _cause), do: :ok

  @doc "Queues the current public channel projection."
  @spec channel_changed(Channel.t()) :: :ok
  def channel_changed(%Channel{name: name} = channel) when is_binary(name) do
    if String.starts_with?(name, "&"), do: :ok, else: enqueue(%{kind: :s2s_channel, channel: channel_snapshot(channel)})
  end

  @doc "Queues one stamped channel list slot, including a deletion tombstone."
  @spec channel_list_changed(String.t(), String.t(), String.t(), boolean(), String.t(), non_neg_integer()) :: :ok
  def channel_list_changed(channel_name_key, mode, mask, present, set_by, set_ms)
      when is_binary(channel_name_key) and is_binary(mode) and is_binary(mask) and is_boolean(present) and
             is_binary(set_by) and is_integer(set_ms) do
    channel_list_changed(channel_name_key, mode, mask, present, set_by, set_ms, next_local_stamp())
  end

  @doc "Queues a channel list slot with the stamp already committed by its repository."
  @spec channel_list_changed(String.t(), String.t(), String.t(), boolean(), String.t(), non_neg_integer(), term()) ::
          :ok
  def channel_list_changed(channel_name_key, mode, mask, present, set_by, set_ms, stamp)
      when is_binary(channel_name_key) and is_binary(mode) and is_binary(mask) and is_boolean(present) and
             is_binary(set_by) and is_integer(set_ms) do
    enqueue(%{
      kind: :s2s_channel_list,
      channel_name_key: channel_name_key,
      mode: mode,
      mask: mask,
      present: present,
      set_by: set_by,
      set_ms: max(set_ms, 1),
      stamp: stamp
    })
  end

  @doc "Allocates the next local ENP stamp when the native manager is active."
  @spec next_local_stamp() :: Identity.stamp() | nil
  def next_local_stamp do
    case local_identity() do
      {:ok, sid, boot} -> Output.next_stamp(sid, boot)
      :error -> nil
    end
  end

  @doc "Queues one remote membership status update until the local transaction commits."
  @spec member_status_changed(map(), String.t(), pos_integer(), String.t(), boolean(), String.t()) :: :ok
  def member_status_changed(channel, uid, join_id, mode, enabled, setter)
      when is_map(channel) and is_binary(uid) and is_integer(join_id) and is_binary(mode) and is_boolean(enabled) and
             is_binary(setter) do
    enqueue(%{
      kind: :s2s_member_status,
      channel: channel,
      uid: uid,
      join_id: join_id,
      mode: mode,
      enabled: enabled,
      setter: setter
    })
  end

  @doc "Drains one committed publication intent outside the Mnesia transaction."
  @spec drain(map()) :: :ok | {:error, term()}
  def drain(%{kind: :s2s_user_put, user: user_snapshot}) do
    with {:ok, user} <- materialize_user(user_snapshot), do: publish_user(user)
  end

  def drain(%{kind: :s2s_user_quit, user: user_snapshot, reason: reason}) do
    with {:ok, user} <- materialize_user(user_snapshot), do: publish_quit(user, reason)
  end

  def drain(%{kind: :s2s_memberships, uid: uid, cause: cause}), do: publish_memberships(uid, cause)
  def drain(%{kind: :s2s_memberships, uid: uid}), do: publish_memberships(uid, nil)

  def drain(%{kind: :s2s_channel, channel: channel_snapshot}) do
    with {:ok, channel} <- materialize_channel(channel_snapshot), do: publish_channel(channel)
  end

  def drain(%{kind: :s2s_channel_list} = intent), do: publish_channel_list(intent)
  def drain(%{kind: :s2s_member_status} = intent), do: publish_member_status(intent)
  def drain(%{kind: :s2s_policy_changed}), do: refresh_policy()
  def drain(_intent), do: :ok

  @doc "Builds the ENP rows for one committed intent without calling the manager."
  @spec rows_for_intent(map(), map()) :: {:ok, [map()]} | {:error, term()}
  @spec rows_for_intent(map(), map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def rows_for_intent(intent, hello, options \\ [])

  def rows_for_intent(%{kind: :s2s_user_put, user: user_value}, hello, options) do
    with {:ok, user} <- materialize_user(user_value) do
      if user.registered == false do
        {:ok, []}
      else
        with {:ok, projection} <-
               Projection.user(user, hello["boot"],
                 sid: hello["sid"],
                 policy_epoch: Keyword.get(options, :policy_epoch),
                 policy: Keyword.get(options, :policy)
               ),
             {:ok, membership_rows} <- membership_rows(user, hello),
             rows <- [%{"kind" => "user.put", "user" => projection} | membership_rows],
             :ok <- ensure_rows(rows) do
          {:ok, rows}
        end
      end
    end
  end

  def rows_for_intent(%{kind: :s2s_user_quit, user: user_value, reason: reason}, hello, _options) do
    with {:ok, user} <- materialize_user(user_value) do
      if user.registered == false do
        {:ok, []}
      else
        row = quit_row(user, reason, hello)
        if Schema.validate_row(row) == :ok, do: {:ok, [row]}, else: {:error, :invalid_quit_row}
      end
    end
  end

  def rows_for_intent(%{kind: :s2s_memberships, uid: uid} = intent, hello, _options) when is_binary(uid) do
    with {:ok, user} <- read_user(uid),
         {:ok, rows} <- membership_rows(user, hello, Map.get(intent, :cause)),
         :ok <- ensure_rows(rows) do
      {:ok, rows}
    end
  end

  def rows_for_intent(%{kind: :s2s_channel, channel: channel_value}, hello, _options) do
    with {:ok, channel} <- materialize_channel(channel_value) do
      list_rows = channel_list_rows(channel.name_key, channel_ref(channel), hello)

      Projection.channel(channel, hello["sid"], hello["boot"],
        stamp: next_stamp_for(hello),
        list_rows: list_rows
      )
    end
  end

  def rows_for_intent(%{kind: :s2s_channel_list} = intent, hello, _options) do
    with {:ok, channel} <- read_channel(intent.channel_name_key),
         row <- list_row(intent, channel_ref(channel), hello),
         :ok <- ensure_rows([row]) do
      {:ok, [%{"kind" => "channel.ensure", "channel" => channel_ref(channel)}, row]}
    end
  end

  def rows_for_intent(_intent, _hello, _options), do: {:error, :unsupported_publication_intent}

  # Output groups are local durable records and can outlive the transaction
  # process that created them. Keep only the public projection inputs here;
  # never retain a User/Channel struct, a PID, a credential, or a DateTime
  # struct in the committed intent.
  defp user_snapshot(%User{} = user) do
    %{
      uid: user.uid,
      home_sid: user.home_sid,
      home_boot: user.home_boot,
      owner_rev: user.owner_rev,
      membership_rev: user.membership_rev,
      nick: user.nick,
      transport: user.transport,
      ip_address: user.ip_address,
      hostname: user.hostname,
      cloaked_hostname: user.cloaked_hostname,
      ident: user.ident,
      realname: user.realname,
      registered: user.registered,
      modes: user.modes,
      away_message: user.away_message,
      identified_as: user.identified_as,
      webirc_secure: user.webirc_secure,
      last_activity: user.last_activity,
      created_at_ms: datetime_ms(user.created_at)
    }
  end

  defp channel_snapshot(%Channel{} = channel) do
    %{
      name_key: channel.name_key,
      name: channel.name,
      born_ms: max(channel.born_ms || datetime_ms(channel.created_at), 1),
      cid: channel.cid,
      modes: channel.modes,
      topic: topic_snapshot(channel.topic)
    }
  end

  defp topic_snapshot(nil), do: nil

  defp topic_snapshot(%Topic{text: text, setter: setter, set_at: set_at}) do
    %{text: text, setter: setter, set_at_ms: datetime_ms(set_at)}
  end

  defp topic_snapshot(text) when is_binary(text), do: %{text: text, setter: "", set_at_ms: 1}

  defp materialize_user(%User{} = user), do: {:ok, user}

  defp materialize_user(snapshot) when is_map(snapshot) do
    with true <- valid_user_snapshot?(snapshot),
         {:ok, created_at} <- datetime_from_ms(Map.get(snapshot, :created_at_ms)) do
      user =
        User.new(%{
          uid: Map.get(snapshot, :uid),
          pid: nil,
          home_sid: Map.get(snapshot, :home_sid),
          home_boot: Map.get(snapshot, :home_boot),
          owner_rev: max(Map.get(snapshot, :owner_rev), 1),
          membership_rev: max(Map.get(snapshot, :membership_rev), 0),
          nick: Map.get(snapshot, :nick),
          transport: Map.get(snapshot, :transport),
          ip_address: Map.get(snapshot, :ip_address),
          port_connected: 0,
          registered: Map.get(snapshot, :registered),
          modes: Map.get(snapshot, :modes),
          identified_as: Map.get(snapshot, :identified_as),
          last_activity: Map.get(snapshot, :last_activity),
          created_at: created_at
        })

      {:ok,
       %{
         user
         | hostname: Map.get(snapshot, :hostname),
           cloaked_hostname: Map.get(snapshot, :cloaked_hostname),
           ident: Map.get(snapshot, :ident),
           realname: Map.get(snapshot, :realname),
           away_message: Map.get(snapshot, :away_message),
           webirc_secure: Map.get(snapshot, :webirc_secure)
       }}
    else
      _ -> {:error, :invalid_user_snapshot}
    end
  rescue
    _ -> {:error, :invalid_user_snapshot}
  end

  defp materialize_user(_snapshot), do: {:error, :invalid_user_snapshot}

  defp valid_user_snapshot?(snapshot) do
    is_binary(Map.get(snapshot, :uid)) and
      (is_nil(Map.get(snapshot, :home_sid)) or is_binary(Map.get(snapshot, :home_sid))) and
      (is_nil(Map.get(snapshot, :home_boot)) or is_binary(Map.get(snapshot, :home_boot))) and
      is_integer(Map.get(snapshot, :owner_rev)) and
      is_integer(Map.get(snapshot, :membership_rev)) and
      (is_nil(Map.get(snapshot, :nick)) or is_binary(Map.get(snapshot, :nick))) and
      Map.get(snapshot, :transport) in [:tcp, :tls, :ws, :wss] and
      valid_ip?(Map.get(snapshot, :ip_address)) and
      (is_nil(Map.get(snapshot, :hostname)) or is_binary(Map.get(snapshot, :hostname))) and
      (is_nil(Map.get(snapshot, :cloaked_hostname)) or is_binary(Map.get(snapshot, :cloaked_hostname))) and
      (is_nil(Map.get(snapshot, :ident)) or is_binary(Map.get(snapshot, :ident))) and
      (is_nil(Map.get(snapshot, :realname)) or is_binary(Map.get(snapshot, :realname))) and
      is_boolean(Map.get(snapshot, :registered)) and
      is_list(Map.get(snapshot, :modes)) and
      (is_nil(Map.get(snapshot, :away_message)) or is_binary(Map.get(snapshot, :away_message))) and
      (is_nil(Map.get(snapshot, :identified_as)) or is_binary(Map.get(snapshot, :identified_as))) and
      (is_nil(Map.get(snapshot, :webirc_secure)) or is_boolean(Map.get(snapshot, :webirc_secure))) and
      is_integer(Map.get(snapshot, :last_activity)) and
      is_integer(Map.get(snapshot, :created_at_ms))
  end

  defp valid_ip?({a, b, c, d})
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) and
              a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
       do: true

  defp valid_ip?({a, b, c, d, e, f, g, h}) do
    Enum.all?([a, b, c, d, e, f, g, h], &is_integer/1) and
      Enum.all?([a, b, c, d, e, f, g, h], &(&1 in 0..65_535))
  end

  defp valid_ip?(_ip), do: false

  defp materialize_channel(%Channel{} = channel), do: {:ok, channel}

  defp materialize_channel(snapshot) when is_map(snapshot) do
    with true <- valid_channel_snapshot?(snapshot),
         {:ok, created_at} <- datetime_from_ms(Map.get(snapshot, :born_ms)),
         {:ok, topic} <- materialize_topic(Map.get(snapshot, :topic)) do
      channel =
        Channel.new(%{
          name: Map.get(snapshot, :name),
          born_ms: Map.get(snapshot, :born_ms),
          cid: Map.get(snapshot, :cid),
          topic: topic,
          modes: Map.get(snapshot, :modes),
          created_at: created_at
        })

      {:ok, %{channel | name_key: Map.get(snapshot, :name_key)}}
    else
      _ -> {:error, :invalid_channel_snapshot}
    end
  rescue
    _ -> {:error, :invalid_channel_snapshot}
  end

  defp materialize_channel(_snapshot), do: {:error, :invalid_channel_snapshot}

  defp valid_channel_snapshot?(snapshot) do
    is_binary(Map.get(snapshot, :name_key)) and
      is_binary(Map.get(snapshot, :name)) and
      is_integer(Map.get(snapshot, :born_ms)) and
      Map.get(snapshot, :born_ms) > 0 and
      is_binary(Map.get(snapshot, :cid)) and
      is_list(Map.get(snapshot, :modes))
  end

  defp materialize_topic(nil), do: {:ok, nil}

  defp materialize_topic(snapshot) when is_map(snapshot) do
    with text when is_binary(text) <- Map.get(snapshot, :text),
         setter when is_binary(setter) <- Map.get(snapshot, :setter),
         {:ok, set_at} <- datetime_from_ms(Map.get(snapshot, :set_at_ms)) do
      {:ok, %Topic{text: text, setter: setter, set_at: set_at}}
    else
      _ -> {:error, :invalid_topic_snapshot}
    end
  end

  defp materialize_topic(_snapshot), do: {:error, :invalid_topic_snapshot}

  defp datetime_ms(%DateTime{} = value), do: max(DateTime.to_unix(value, :millisecond), 1)
  defp datetime_ms(_value), do: 1

  defp datetime_from_ms(value) when is_integer(value) and value > 0 do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> {:ok, datetime}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp datetime_from_ms(_value), do: {:error, :invalid_timestamp}

  defp enqueue(intent) do
    if intent.kind == :s2s_policy_changed and Process.get({__MODULE__, :suppress_policy_refresh}, false) do
      :ok
    else
      collect_intent(intent)
    end
  end

  defp collect_intent(intent) do
    case Output.collect_intent(intent) do
      :inactive ->
        :ok

      :ok ->
        :ok

      {:error, reason} ->
        if Memento.Transaction.inside?() do
          Memento.Transaction.abort({:s2s_output_capacity, reason})
        else
          :ok
        end
    end
  end

  defp publish_user(user) do
    with {:ok, manager, hello} <- manager_context(),
         {:ok, policy_epoch, policy} <- manager_policy(manager),
         {:ok, rows} <-
           rows_for_intent(%{kind: :s2s_user_put, user: user}, hello,
             policy_epoch: policy_epoch,
             policy: policy
           ),
         :ok <- publish_group(manager, rows) do
      :ok
    else
      {:error, :s2s_disabled} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp publish_memberships(uid, cause) do
    with {:ok, user} <- read_user(uid),
         {:ok, manager, hello} <- manager_context(),
         {:ok, rows} <- rows_for_intent(%{kind: :s2s_memberships, uid: user.uid, cause: cause}, hello),
         :ok <- publish_group(manager, rows) do
      :ok
    else
      {:error, :s2s_disabled} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp publish_quit(%User{registered: false}, _reason), do: :ok

  defp publish_quit(user, reason) do
    with {:ok, manager, hello} <- manager_context(),
         {:ok, rows} <- rows_for_intent(%{kind: :s2s_user_quit, user: user, reason: reason}, hello),
         :ok <- publish_group(manager, rows) do
      :ok
    else
      {:error, :s2s_disabled} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp publish_channel(channel) do
    with {:ok, manager, hello} <- manager_context(),
         {:ok, rows} <- rows_for_intent(%{kind: :s2s_channel, channel: channel}, hello),
         :ok <- publish_group(manager, rows) do
      :ok
    else
      {:error, :s2s_disabled} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp publish_channel_list(intent) do
    with {:ok, manager, hello} <- manager_context(),
         {:ok, rows} <- rows_for_intent(intent, hello),
         :ok <- publish_group(manager, rows) do
      :ok
    else
      {:error, :s2s_disabled} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp publish_member_status(intent) do
    case Process.whereis(Manager) do
      manager when is_pid(manager) ->
        try do
          Manager.publish_member_status(
            manager,
            intent.channel,
            intent.uid,
            intent.join_id,
            intent.mode,
            intent.enabled,
            intent.setter
          )
        catch
          :exit, reason -> {:error, {:manager_unavailable, reason}}
        end

      _ ->
        :ok
    end
  rescue
    error -> {:error, {:publication_failed, Exception.message(error)}}
  end

  defp refresh_policy do
    case Process.whereis(Manager) do
      manager when is_pid(manager) ->
        try do
          Manager.refresh_policy(manager)
        catch
          :exit, reason -> {:error, {:manager_unavailable, reason}}
        end

      _ ->
        :ok
    end
  rescue
    error -> {:error, {:policy_refresh_failed, Exception.message(error)}}
  end

  defp membership_rows(user, hello, cause \\ nil) do
    records =
      Memento.transaction!(fn ->
        UserChannels.get_by_uid(user.uid)
        |> Enum.reject(&String.starts_with?(&1.channel_name_key, "&"))
      end)

    channel_refs =
      Memento.transaction!(fn ->
        Channels.get_all()
        |> Enum.reject(&String.starts_with?(&1.name, "&"))
        |> Map.new(fn channel -> {channel.name_key, channel_ref(channel)} end)
      end)

    with {:ok, membership, statuses} <-
           Projection.memberships(user, records, hello["sid"], hello["boot"],
             sid: hello["sid"],
             channel_refs: channel_refs,
             status_stamp: next_stamp_for(hello),
             cause: cause
           ) do
      {:ok, [membership | statuses]}
    end
  rescue
    _ -> {:error, :membership_projection_failed}
  end

  defp read_user(uid) do
    Memento.transaction!(fn -> Users.get_by_uid(uid) end)
  rescue
    _ -> {:error, :user_not_found}
  end

  defp read_channel(name_key) do
    Memento.transaction!(fn -> Channels.get_by_name(name_key) end)
  rescue
    _ -> {:error, :channel_not_found}
  end

  defp channel_list_rows(name_key, ref, hello) do
    Memento.transaction!(fn ->
      live_rows =
        [
          {"b", ChannelBans.get_by_channel_name_key(name_key)},
          {"e", ChannelExcepts.get_by_channel_name_key(name_key)},
          {"I", ChannelInvexes.get_by_channel_name_key(name_key)}
        ]
        |> Enum.flat_map(fn {mode, records} ->
          Enum.map(records, fn record ->
            set_ms = max(DateTime.to_unix(record.created_at, :millisecond), 1)

            %{
              "kind" => "channel.list",
              "channel" => ref,
              "mode" => mode,
              "mask" => record.mask,
              "present" => true,
              "set_by" => record.setter,
              "set_ms" => set_ms,
              "stamp" => record.stamp || next_stamp_for(hello)
            }
          end)
        end)

      tombstone_rows =
        Enum.map(ChannelListTombstones.get_by_channel_name_key(name_key), fn tombstone ->
          %{
            "kind" => "channel.list",
            "channel" => ref,
            "mode" => tombstone.mode,
            "mask" => tombstone.mask,
            "present" => false,
            "set_by" => tombstone.set_by,
            "set_ms" => tombstone.set_ms,
            "stamp" => tombstone.stamp || next_stamp_for(hello)
          }
        end)

      live_rows ++ tombstone_rows
    end)
  rescue
    _ -> []
  end

  defp list_row(intent, ref, hello) do
    %{
      "kind" => "channel.list",
      "channel" => ref,
      "mode" => intent.mode,
      "mask" => intent.mask,
      "present" => intent.present,
      "set_by" => intent.set_by,
      "set_ms" => intent.set_ms,
      "stamp" => intent.stamp || next_stamp_for(hello)
    }
  end

  defp ensure_rows(rows) do
    if Enum.all?(rows, &(ElixIRCd.Server.S2S.Schema.validate_row(&1) == :ok)),
      do: :ok,
      else: {:error, :invalid_publication_rows}
  end

  defp next_stamp_for(%{"sid" => sid, "boot" => boot}) do
    Output.next_stamp(sid, boot)
  rescue
    _ -> nil
  end

  defp next_stamp_for(_hello), do: nil

  defp local_identity do
    s2s = Application.get_env(:elixircd, :s2s, [])
    enabled = value(s2s, :enabled, false)
    sid = value(s2s, :server_id, nil)
    boot = Application.get_env(:elixircd, :s2s_boot, value(s2s, :boot, nil))

    if enabled and Identity.valid_sid?(sid) and Identity.valid_id?(boot),
      do: {:ok, sid, boot},
      else: :error
  end

  defp value(section, key, default) when is_map(section), do: Map.get(section, key, default)
  defp value(section, key, default) when is_list(section), do: Keyword.get(section, key, default)
  defp value(_section, _key, default), do: default

  defp quit_row(user, reason, hello) do
    home = %{"sid" => user.home_sid || hello["sid"], "boot" => user.home_boot || hello["boot"]}

    %{
      "kind" => "user.quit",
      "uid" => user.uid,
      "home" => home,
      "rev" => max(user.owner_rev || 1, 1) + 1,
      "reason" => normalize_reason(reason),
      "action" => "quit",
      "by" => %{"server" => hello["sid"]}
    }
  end

  defp manager_context do
    case Process.whereis(Manager) do
      nil ->
        {:error, :s2s_disabled}

      manager ->
        hello = Manager.local_hello(manager)

        if Identity.valid_sid?(hello["sid"]) and Identity.valid_id?(hello["boot"]),
          do: {:ok, manager, hello},
          else: {:error, :invalid_manager_hello}
    end
  catch
    :exit, _ -> {:error, :manager_unavailable}
  end

  defp manager_policy(manager) do
    runtime = Manager.runtime_view(manager)
    {:ok, runtime.policy.epoch, runtime.policy}
  catch
    :exit, _ -> {:error, :manager_unavailable}
  end

  defp channel_ref(%Channel{} = channel) do
    %{
      "name" => channel.name,
      "born_ms" => max(channel.born_ms || DateTime.to_unix(channel.created_at, :millisecond), 1),
      "cid" => channel.cid
    }
  end

  defp normalize_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 4_096)
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(_reason), do: "connection closed"

  defp publish_group(manager, rows) do
    Enum.reduce_while(Enum.chunk_every(rows, 256), :ok, fn chunk, :ok ->
      case Manager.publish_rows(manager, chunk) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
