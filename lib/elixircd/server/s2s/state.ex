defmodule ElixIRCd.Server.S2S.State do
  @moduledoc """
  Pure ENP state algebra.

  The functions here do not write Mnesia or send a message. They are the small
  deterministic operations used by local origin paths, snapshot application and
  request owners, which keeps merge behaviour independent of arrival order.
  """

  alias ElixIRCd.Server.S2S.Identity

  @hard_membership_limit 128

  @type register :: %{stamp: Identity.stamp(), value: term()}

  @doc "Creates the local network control state."
  @spec new(keyword()) :: map()
  def new(options \\ []) do
    %{
      sid: Keyword.fetch!(options, :sid),
      boot: Keyword.get(options, :boot, Identity.boot()),
      logical_counter: 0,
      output_sequence: 0,
      ready?: false
    }
  end

  @doc "Observes a received logical counter without creating an output stamp."
  @spec observe_counter(map(), non_neg_integer()) :: map()
  def observe_counter(state, counter) when is_integer(counter) and counter >= 0 do
    %{state | logical_counter: max(state.logical_counter, counter)}
  end

  @doc "Allocates the next local stamp under the node-local ordering barrier."
  @spec next_stamp(map()) :: {Identity.stamp(), map()}
  def next_stamp(%{logical_counter: counter, sid: sid, boot: boot} = state) do
    next = counter + 1

    if next > Identity.max_uint() do
      raise ArgumentError, "ENP logical counter exhausted"
    end

    {[next, sid, boot], %{state | logical_counter: next}}
  end

  @doc "Allocates one local committed output sequence."
  @spec next_output(map()) :: {pos_integer(), map()}
  def next_output(%{output_sequence: sequence} = state) do
    next = sequence + 1
    if next > Identity.max_uint(), do: raise(ArgumentError, "ENP output sequence exhausted")
    {next, %{state | output_sequence: next}}
  end

  @doc "Merges one stamped register using the ENP total stamp order."
  @spec merge_register(register() | nil, Identity.stamp(), term()) ::
          {:ok, :inserted | :updated | :unchanged, register()} | {:error, :stamp_conflict}
  def merge_register(nil, stamp, value), do: {:ok, :inserted, %{stamp: stamp, value: value}}

  def merge_register(%{stamp: existing_stamp, value: existing_value} = existing, stamp, value) do
    case Identity.compare_stamp(stamp, existing_stamp) do
      :gt -> {:ok, :updated, %{existing | stamp: stamp, value: value}}
      :lt -> {:ok, :unchanged, existing}
      :eq when existing_value == value -> {:ok, :unchanged, existing}
      :eq -> {:error, :stamp_conflict}
    end
  end

  @doc "Compares two channel incarnations."
  @spec incarnation(map(), map()) :: :older | :same | :newer
  def incarnation(%{born_ms: left_born, cid: left_cid}, %{born_ms: right_born, cid: right_cid}) do
    case Identity.compare_incarnation(left_born, left_cid, right_born, right_cid) do
      :lt -> :older
      :eq -> :same
      :gt -> :newer
    end
  end

  @doc "Selects the winning channel incarnation from two channel references."
  @spec winning_incarnation(map(), map()) :: map()
  def winning_incarnation(left, right) do
    case incarnation(left, right) do
      :older -> left
      :same -> left
      :newer -> right
    end
  end

  @doc "Merges a versioned channel field without touching unrelated fields."
  @spec merge_channel_field(map(), String.t(), Identity.stamp(), term()) ::
          {:ok, map(), :inserted | :updated | :unchanged} | {:error, :stamp_conflict}
  def merge_channel_field(channel, field, stamp, value) when is_map(channel) and is_binary(field) do
    registers = Map.get(channel, :registers, %{})

    case merge_register(Map.get(registers, field), stamp, value) do
      {:ok, status, register} -> {:ok, %{channel | registers: Map.put(registers, field, register)}, status}
      {:error, _} = error -> error
    end
  end

  @doc "Merges a list entry while retaining a removal tombstone."
  @spec merge_list_slot(map(), term(), Identity.stamp(), boolean(), map()) ::
          {:ok, map(), :inserted | :updated | :unchanged} | {:error, :stamp_conflict | :slot_capacity}
  def merge_list_slot(channel, key, stamp, present, metadata \\ %{}) do
    slots = Map.get(channel, :list_slots, %{})

    with :ok <- capacity_for_slot(slots, key, channel),
         {:ok, status, slot} <- merge_register(Map.get(slots, key), stamp, Map.merge(metadata, %{present: present})) do
      {:ok, %{channel | list_slots: Map.put(slots, key, slot)}, status}
    end
  end

  @doc "Computes a deterministic effective nickname for every live claimant."
  @spec nickname_projection([map()], keyword()) :: {:ok, %{optional(String.t()) => String.t()}} | {:error, term()}
  def nickname_projection(users, options \\ []) when is_list(users) do
    mapping =
      Keyword.get(options, :case_mapping, Application.get_env(:elixircd, :settings, [])[:case_mapping] || :rfc1459)

    with :ok <- unique_uids(users),
         :ok <- unique_requested_names(users, mapping),
         {:ok, projection} <- build_nickname_projection(users, mapping) do
      if injective?(projection), do: {:ok, projection}, else: {:error, :nickname_collision}
    end
  end

  @doc "Returns the deterministic generated fallback for a losing nickname claimant."
  @spec fallback_nickname(String.t()) :: String.t()
  def fallback_nickname(uid), do: "G" <> uid

  @doc "Checks the reserved fallback namespace."
  @spec fallback_nickname?(String.t()) :: boolean()
  def fallback_nickname?(nick) when is_binary(nick) do
    case String.upcase(nick) do
      <<"G", uid::binary-size(26)>> -> Identity.valid_id?(uid)
      _ -> false
    end
  end

  def fallback_nickname?(_nick), do: false

  @doc "Checks whether a fallback nickname belongs to the supplied UID."
  @spec fallback_nickname_for?(String.t(), String.t()) :: boolean()
  def fallback_nickname_for?(nick, uid) when is_binary(nick) and is_binary(uid) do
    Identity.valid_id?(uid) and
      fallback_nickname?(nick) and
      String.upcase(nick) == String.upcase(fallback_nickname(uid))
  end

  def fallback_nickname_for?(_nick, _uid), do: false

  @doc "Replaces a home-owned complete membership set and returns a generation-aware diff."
  @spec replace_memberships(non_neg_integer(), [map()], non_neg_integer(), [map()], keyword()) ::
          {:ok, %{added: [map()], removed: [map()], changed: [map()]}} | {:error, term()}
  def replace_memberships(old_revision, old_entries, new_revision, new_entries, options \\ []) do
    limit = min(Keyword.get(options, :max_memberships, 20), @hard_membership_limit)

    mapping =
      Keyword.get(options, :case_mapping, Application.get_env(:elixircd, :settings, [])[:case_mapping] || :rfc1459)

    cond do
      not valid_revision?(old_revision) or not valid_revision?(new_revision) ->
        {:error, :invalid_membership_revision}

      new_revision < old_revision ->
        {:error, :stale_membership_revision}

      new_revision == 0 and new_entries != [] ->
        {:error, :invalid_zero_membership_revision}

      length(new_entries) > limit ->
        {:error, :membership_limit}

      duplicate_membership_channels?(new_entries, mapping) ->
        {:error, :duplicate_membership_channel}

      new_revision == old_revision and
          canonical_entries(old_entries, mapping) != canonical_entries(new_entries, mapping) ->
        {:error, :membership_revision_conflict}

      new_revision == old_revision ->
        {:ok, %{added: [], removed: [], changed: []}}

      true ->
        {:ok, membership_diff(old_entries, new_entries, mapping)}
    end
  end

  @doc "Builds an immutable public user projection from a local user-like map."
  @spec user_projection(map(), map(), keyword()) :: map()
  def user_projection(user, home, options \\ []) do
    modes = Enum.map(Map.get(user, :modes, []), &mode_string/1) |> Enum.reject(&(&1 in ["r", "Z"]))

    %{
      "uid" => Map.fetch!(user, :uid),
      "home" => %{"sid" => Map.fetch!(home, :sid), "boot" => Map.fetch!(home, :boot)},
      "rev" => Map.get(user, :owner_revision, 1),
      "requested_nick" => Map.get(user, :nick, Map.get(user, :requested_nick, "")),
      "signon_ms" => Map.get(user, :signon_ms, Identity.now_ms()),
      "ident" => Map.get(user, :ident, ""),
      "realhost" => Map.get(user, :realhost, Map.get(user, :hostname, "")),
      "displayhost" => Map.get(user, :displayhost, Map.get(user, :cloaked_hostname, "")),
      "address" => Map.get(user, :address, inspect(Map.get(user, :ip_address, ""))),
      "secure_client" => Map.get(user, :secure_client, Map.get(user, :transport) in [:tls, :wss]),
      "client_certfp" => Map.get(user, :client_certfp),
      "modes" => modes,
      "oper_role" => Map.get(user, :oper_role),
      "away" => away_projection(user),
      "realname" => Map.get(user, :realname, ""),
      "binding" => binding_projection(user),
      "case_mapping" => Keyword.get(options, :case_mapping)
    }
    |> Map.delete("case_mapping")
  end

  defp unique_uids(users) do
    uids = Enum.map(users, &Map.get(&1, :uid, Map.get(&1, "uid")))

    if Enum.all?(uids, &Identity.valid_id?/1) and length(uids) == length(Enum.uniq(uids)),
      do: :ok,
      else: {:error, :duplicate_or_invalid_uid}
  end

  defp unique_requested_names(users, _mapping) do
    if Enum.all?(users, fn user ->
         uid = Map.get(user, :uid, Map.get(user, "uid"))
         requested = Map.get(user, :requested_nick, Map.get(user, "requested_nick"))

         is_binary(requested) and
           (not fallback_nickname?(requested) or fallback_nickname_for?(requested, uid))
       end) do
      :ok
    else
      {:error, :invalid_requested_nick}
    end
  end

  defp build_nickname_projection(users, mapping) do
    users
    |> Enum.group_by(fn user -> normalize(Map.get(user, :requested_nick, Map.get(user, "requested_nick")), mapping) end)
    |> Enum.reduce_while({:ok, %{}}, fn {_key, claimants}, {:ok, projection} ->
      sorted = Enum.sort_by(claimants, &Map.get(&1, :uid, Map.get(&1, "uid")))

      case sorted do
        [] ->
          {:cont, {:ok, projection}}

        [winner | losers] ->
          winner_uid = Map.get(winner, :uid, Map.get(winner, "uid"))
          requested = Map.get(winner, :requested_nick, Map.get(winner, "requested_nick"))
          projection = Map.put(projection, winner_uid, requested)

          projection =
            Enum.reduce(losers, projection, fn loser, acc ->
              uid = Map.get(loser, :uid, Map.get(loser, "uid"))
              Map.put(acc, uid, fallback_nickname(uid))
            end)

          {:cont, {:ok, projection}}
      end
    end)
  end

  defp injective?(projection), do: map_size(projection) == projection |> Map.values() |> Enum.uniq() |> length()

  defp membership_diff(old_entries, new_entries, mapping) do
    old = Map.new(old_entries, &{entry_key(&1, mapping), &1})
    new = Map.new(new_entries, &{entry_key(&1, mapping), &1})

    %{
      added: for({key, entry} <- new, not Map.has_key?(old, key), do: entry),
      removed: for({key, entry} <- old, not Map.has_key?(new, key), do: entry),
      changed: for({key, entry} <- new, Map.has_key?(old, key) and old[key] != entry, do: entry)
    }
  end

  defp canonical_entries(entries, mapping), do: entries |> Enum.map(&{entry_key(&1, mapping), &1}) |> Enum.sort()

  defp duplicate_membership_channels?(entries, mapping) do
    keys = Enum.map(entries, &entry_key(&1, mapping))
    length(keys) != length(Enum.uniq(keys))
  end

  defp entry_key(entry, mapping), do: normalize(Map.get(entry, :channel, Map.get(entry, "channel")), mapping)

  defp valid_revision?(value), do: Identity.valid_uint?(value)

  defp capacity_for_slot(slots, key, channel) do
    limit = Map.get(channel, :list_slot_limit, 4_096)

    if Map.has_key?(slots, key) or map_size(slots) < limit, do: :ok, else: {:error, :slot_capacity}
  end

  defp mode_string(mode) when is_atom(mode), do: Atom.to_string(mode)
  defp mode_string(mode), do: mode

  defp away_projection(user) do
    case Map.get(user, :away_message) do
      nil -> nil
      text -> %{"text" => text, "since_ms" => Map.get(user, :away_since_ms, Identity.now_ms())}
    end
  end

  defp binding_projection(user) do
    case {Map.get(user, :account_id), Map.get(user, :auth_epoch), Map.get(user, :policy_epoch)} do
      {account_id, auth_epoch, policy_epoch}
      when is_binary(account_id) and is_integer(auth_epoch) and is_binary(policy_epoch) ->
        %{"account_id" => account_id, "auth_epoch" => auth_epoch, "policy_epoch" => policy_epoch}

      _ ->
        nil
    end
  end

  defp normalize(value, :ascii), do: ascii_lower(value)

  defp normalize(value, :strict_rfc1459) do
    value
    |> ascii_lower()
    |> String.replace(["{", "}", "|"], fn
      "{" -> "["
      "}" -> "]"
      "|" -> "\\"
    end)
  end

  defp normalize(value, _mapping) do
    value
    |> ascii_lower()
    |> String.replace(["{", "}", "|", "~"], fn
      "{" -> "["
      "}" -> "]"
      "|" -> "\\"
      "~" -> "^"
    end)
  end

  defp ascii_lower(value) when is_binary(value) do
    for <<byte <- value>>, into: <<>>, do: <<if(byte in ?A..?Z, do: byte + 32, else: byte)>>
  end
end
