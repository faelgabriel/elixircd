defmodule ElixIRCd.ServerLink.Replica do
  @moduledoc """
  PID-free remote user and channel state with atomic snapshots and ordered changes.

  A snapshot is staged privately until its declared count is complete. A
  failed snapshot leaves the last committed view intact. Every user event and
  channel delta must follow the origin's cursor exactly, so gaps and stale epochs fail
  closed and require a fresh snapshot.
  """

  alias ElixIRCd.ServerLink.Frame
  alias ElixIRCd.ServerLink.NickAuthority
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Protocol

  @max_snapshot_bytes 64 * 1_024 * 1_024
  @max_network_bytes 256 * 1_024 * 1_024

  defstruct origins: %{},
            staging: %{},
            deltas: %{},
            users: %{},
            nick_keys: %{},
            nick_claims: %{},
            channels: %{},
            members: %{},
            lists: %{},
            invites: %{},
            usage: %{},
            total_bytes: 0,
            staged_bytes: 0,
            max_snapshot_bytes: @max_snapshot_bytes,
            max_network_bytes: @max_network_bytes

  @type identity :: {String.t(), String.t()}
  @type user_index :: %{optional(identity()) => UserPayload.wire_user()}
  @type nick_index :: %{optional(String.t()) => identity()}
  @type claim_index :: %{optional(String.t()) => MapSet.t(identity())}

  @type t :: %__MODULE__{
          origins: map(),
          staging: map(),
          deltas: map(),
          users: user_index(),
          nick_keys: nick_index(),
          nick_claims: claim_index(),
          channels: map(),
          members: map(),
          lists: map(),
          invites: map(),
          usage: map(),
          total_bytes: non_neg_integer(),
          staged_bytes: non_neg_integer(),
          max_snapshot_bytes: pos_integer(),
          max_network_bytes: pos_integer()
        }

  @doc "Creates an empty remote-state replica."
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      max_snapshot_bytes: Keyword.get(options, :max_snapshot_bytes, @max_snapshot_bytes),
      max_network_bytes: Keyword.get(options, :max_network_bytes, @max_network_bytes)
    }
  end

  @doc "Applies one authenticated frame; cross-origin nick collisions retain both UID records."
  @spec apply(t(), map()) :: {:ok, t()} | {:error, atom()}
  def apply(replica, frame) do
    case Frame.validate(frame) do
      :ok -> apply_valid(replica, frame)
      {:error, _} -> {:error, :invalid_frame}
    end
  end

  @doc "Drops all state owned by one origin after its route or link disappears."
  @spec drop_origin(t(), String.t()) :: t()
  def drop_origin(replica, origin) do
    users = discard_origin(replica.users, origin)
    {nick_claims, nick_keys} = index_users(users)
    {channels, members, lists, invites} = discard_channel_origin(replica, origin)
    released_bytes = get_in(replica.usage, [origin, :bytes]) || 0
    released_staged_bytes = get_in(replica.staging, [origin, :bytes]) || 0

    %{
      replica
      | users: users,
        nick_keys: nick_keys,
        nick_claims: nick_claims,
        channels: channels,
        members: members,
        lists: lists,
        invites: invites,
        usage: Map.delete(replica.usage, origin),
        total_bytes: replica.total_bytes - released_bytes,
        staged_bytes: replica.staged_bytes - released_staged_bytes,
        origins: Map.delete(replica.origins, origin),
        staging: Map.delete(replica.staging, origin),
        deltas: Map.delete(replica.deltas, origin)
    }
  end

  @doc "Finds a remote user by network nickname."
  @spec get_by_nick(t(), String.t()) :: {:ok, map()} | :error
  def get_by_nick(replica, nick) do
    with {:ok, key} <- Map.fetch(replica.nick_keys, CaseMapping.normalize(nick)) do
      Map.fetch(replica.users, key)
    end
  end

  @doc "Finds a committed remote user by its owning server and network UID."
  @spec get_by_uid(t(), String.t(), String.t()) :: {:ok, map()} | :error
  def get_by_uid(replica, origin, uid), do: Map.fetch(replica.users, {origin, uid})

  @doc "Returns the committed users for one origin."
  @spec users_from(t(), String.t()) :: [map()]
  def users_from(replica, origin) do
    for {{^origin, _uid}, user} <- replica.users, do: user
  end

  @doc "Returns committed channel metadata contributed by one origin."
  @spec channels_from(t(), String.t()) :: [map()]
  def channels_from(replica, origin), do: for({{^origin, _key}, channel} <- replica.channels, do: channel)

  @doc "Returns committed memberships contributed by one origin."
  @spec members_from(t(), String.t()) :: [map()]
  def members_from(replica, origin), do: for({{^origin, _key}, member} <- replica.members, do: member)

  @doc "Returns committed mode-list entries contributed by one origin."
  @spec lists_from(t(), String.t()) :: [map()]
  def lists_from(replica, origin), do: for({{^origin, _key}, entry} <- replica.lists, do: entry)

  @doc "Returns committed invites contributed by one origin."
  @spec invites_from(t(), String.t()) :: [map()]
  def invites_from(replica, origin), do: for({{^origin, _key}, invite} <- replica.invites, do: invite)

  @doc "Returns the committed epoch and cursor for one origin."
  @spec origin_state(t(), String.t()) :: {:ok, %{epoch: String.t(), cursor: non_neg_integer()}} | :error
  def origin_state(replica, origin), do: Map.fetch(replica.origins, origin)

  defp apply_valid(replica, %{"type" => "snapshot_begin"} = frame) do
    origin = frame["origin"]

    cond do
      Map.has_key?(replica.staging, origin) or Map.has_key?(replica.deltas, origin) ->
        {:error, :snapshot_in_progress}

      stale_snapshot?(replica.origins[origin], frame) ->
        {:error, :stale_snapshot}

      true ->
        stage = %{
          epoch: frame["epoch"],
          cursor: frame["cursor"],
          expected: frame["count"],
          expected_channels: Map.get(frame, "channel_count", 0),
          expected_members: Map.get(frame, "member_count", 0),
          expected_lists: Map.get(frame, "list_count", 0),
          expected_invites: Map.get(frame, "invite_count", 0),
          bytes: 0,
          users: %{},
          nicks: %{},
          channels: %{},
          members: %{},
          lists: %{},
          invites: %{}
        }

        {:ok, %{replica | staging: Map.put(replica.staging, origin, stage)}}
    end
  end

  defp apply_valid(replica, %{"type" => type} = frame)
       when type in ["snapshot_channel", "snapshot_member", "snapshot_list", "snapshot_invite"] do
    origin = frame["origin"]
    incoming_epoch = frame["epoch"]

    case Map.fetch(replica.staging, origin) do
      {:ok, %{epoch: ^incoming_epoch} = stage} -> stage_channel_entry(replica, origin, stage, type, frame)
      _ -> {:error, :snapshot_not_started}
    end
  end

  defp apply_valid(replica, %{"type" => "snapshot_user"} = frame) do
    origin = frame["origin"]
    incoming_epoch = frame["epoch"]
    user = frame["user"]
    nick_key = CaseMapping.normalize(user["nick"])

    case Map.fetch(replica.staging, origin) do
      {:ok, %{epoch: ^incoming_epoch} = stage} ->
        cond do
          Map.has_key?(stage.users, user["uid"]) ->
            {:error, :duplicate_uid}

          Map.has_key?(stage.nicks, nick_key) ->
            {:error, :nick_collision}

          map_size(stage.users) >= stage.expected ->
            {:error, :snapshot_overflow}

          stage.bytes + :erlang.external_size(user) > replica.max_snapshot_bytes ->
            {:error, :snapshot_too_large}

          replica.total_bytes + replica.staged_bytes + :erlang.external_size(user) > replica.max_network_bytes ->
            {:error, :network_state_too_large}

          true ->
            put_staged_user(replica, origin, stage, nick_key, user)
        end

      _ ->
        {:error, :snapshot_not_started}
    end
  end

  defp apply_valid(replica, %{"type" => "snapshot_end"} = frame) do
    origin = frame["origin"]
    incoming_epoch = frame["epoch"]

    case Map.fetch(replica.staging, origin) do
      {:ok, %{epoch: ^incoming_epoch} = stage} ->
        finish_snapshot(replica, origin, stage)

      _ ->
        {:error, :snapshot_not_started}
    end
  end

  defp apply_valid(replica, %{"type" => "delta_begin"} = frame) do
    with :ok <- next_event?(replica, frame) do
      origin = frame["origin"]
      delta = %{epoch: frame["epoch"], sequence: frame["sequence"], expected: frame["count"], entries: []}
      {:ok, %{replica | deltas: Map.put(replica.deltas, origin, delta)}}
    end
  end

  defp apply_valid(replica, %{"type" => "delta_entry"} = frame) do
    origin = frame["origin"]
    incoming_epoch = frame["epoch"]

    case Map.fetch(replica.deltas, origin) do
      {:ok, %{epoch: ^incoming_epoch} = delta} when length(delta.entries) < delta.expected ->
        updated = %{delta | entries: [frame | delta.entries]}
        {:ok, %{replica | deltas: Map.put(replica.deltas, origin, updated)}}

      {:ok, %{epoch: ^incoming_epoch}} ->
        {:error, :delta_overflow}

      _ ->
        {:error, :delta_not_started}
    end
  end

  defp apply_valid(replica, %{"type" => "delta_end"} = frame) do
    origin = frame["origin"]
    incoming_epoch = frame["epoch"]
    incoming_sequence = frame["sequence"]

    case Map.fetch(replica.deltas, origin) do
      {:ok, %{epoch: ^incoming_epoch, sequence: ^incoming_sequence} = delta} -> finish_delta(replica, origin, delta)
      _ -> {:error, :delta_not_started}
    end
  end

  defp apply_valid(replica, %{"type" => "user_upsert"} = frame) do
    origin = frame["origin"]
    user = frame["user"]
    key = {origin, user["uid"]}

    with :ok <- next_event?(replica, frame),
         :ok <- stable_registration?(Map.get(replica.users, key), user),
         :ok <- no_same_origin_nick_collision?(replica, origin, user),
         {:ok, usage, total_bytes} <- reserve_usage(replica, origin, Map.get(replica.users, key), user) do
      old_user = Map.get(replica.users, key)
      users = Map.put(replica.users, key, user)
      claims = replica.nick_claims |> remove_claim(key, old_user) |> add_claim(key, user)
      nick_keys = refresh_nicks(replica.nick_keys, claims, users, [old_user, user])

      {:ok,
       %{
         replica
         | users: users,
           nick_keys: nick_keys,
           nick_claims: claims,
           usage: usage,
           total_bytes: total_bytes,
           origins: put_cursor(replica.origins, origin, frame["sequence"])
       }}
    end
  end

  defp apply_valid(replica, %{"type" => "user_remove"} = frame) do
    origin = frame["origin"]
    key = {origin, frame["uid"]}

    with :ok <- next_event?(replica, frame),
         {:ok, user} <- Map.fetch(replica.users, key) do
      members =
        Map.reject(replica.members, fn {{home, {_channel, uid}}, _entry} -> home == origin and uid == frame["uid"] end)

      invites =
        Map.reject(replica.invites, fn {{home, {_channel, uid}}, _entry} -> home == origin and uid == frame["uid"] end)

      removed_members = for {entry_key, entry} <- replica.members, not Map.has_key?(members, entry_key), do: entry
      removed_invites = for {entry_key, entry} <- replica.invites, not Map.has_key?(invites, entry_key), do: entry
      removed = [user | removed_members ++ removed_invites]
      users = Map.delete(replica.users, key)
      claims = remove_claim(replica.nick_claims, key, user)
      nick_keys = refresh_nicks(replica.nick_keys, claims, users, [user])
      previous_usage = Map.fetch!(replica.usage, origin)

      usage = %{
        previous_usage
        | count: previous_usage.count - length(removed),
          bytes: previous_usage.bytes - Enum.sum(Enum.map(removed, &:erlang.external_size/1))
      }

      {:ok,
       %{
         replica
         | users: users,
           nick_keys: nick_keys,
           nick_claims: claims,
           members: members,
           invites: invites,
           usage: Map.put(replica.usage, origin, usage),
           total_bytes: replica.total_bytes - (previous_usage.bytes - usage.bytes),
           origins: put_cursor(replica.origins, origin, frame["sequence"])
       }}
    else
      :error -> {:error, :unknown_uid}
      error -> error
    end
  end

  defp apply_valid(_replica, _frame), do: {:error, :unexpected_frame}

  defp put_staged_user(replica, origin, stage, nick_key, user) do
    stage = %{
      stage
      | users: Map.put(stage.users, user["uid"], user),
        nicks: Map.put(stage.nicks, nick_key, user["uid"]),
        bytes: stage.bytes + :erlang.external_size(user)
    }

    {:ok,
     %{
       replica
       | staging: Map.put(replica.staging, origin, stage),
         staged_bytes: replica.staged_bytes + :erlang.external_size(user)
     }}
  end

  defp stage_channel_entry(replica, origin, stage, type, frame) do
    {field, expected_field, entry, key} = staged_channel_identity(type, frame)
    entries = Map.fetch!(stage, field)

    cond do
      Map.has_key?(entries, key) ->
        {:error, :duplicate_channel_entry}

      map_size(entries) >= Map.fetch!(stage, expected_field) ->
        {:error, :snapshot_overflow}

      stage.bytes + :erlang.external_size(entry) > replica.max_snapshot_bytes ->
        {:error, :snapshot_too_large}

      replica.total_bytes + replica.staged_bytes + :erlang.external_size(entry) > replica.max_network_bytes ->
        {:error, :network_state_too_large}

      true ->
        stage = %{stage | bytes: stage.bytes + :erlang.external_size(entry)}
        stage = Map.put(stage, field, Map.put(entries, key, entry))

        {:ok,
         %{
           replica
           | staging: Map.put(replica.staging, origin, stage),
             staged_bytes: replica.staged_bytes + :erlang.external_size(entry)
         }}
    end
  end

  defp staged_channel_identity("snapshot_channel", %{"channel" => entry}) do
    {:channels, :expected_channels, entry, CaseMapping.normalize(entry["name"])}
  end

  defp staged_channel_identity("snapshot_member", %{"member" => entry}) do
    {:members, :expected_members, entry, {CaseMapping.normalize(entry["channel"]), entry["uid"]}}
  end

  defp staged_channel_identity("snapshot_list", %{"list" => entry}) do
    key = {CaseMapping.normalize(entry["channel"]), entry["kind"], Protocol.mask_key(entry["mask"])}
    {:lists, :expected_lists, entry, key}
  end

  defp staged_channel_identity("snapshot_invite", %{"invite" => entry}) do
    {:invites, :expected_invites, entry, {CaseMapping.normalize(entry["channel"]), entry["uid"]}}
  end

  defp finish_snapshot(replica, origin, stage) do
    old_users_removed = discard_origin(replica.users, origin)
    previous_bytes = get_in(replica.usage, [origin, :bytes]) || 0
    total_bytes = replica.total_bytes - previous_bytes + stage.bytes

    cond do
      incomplete_snapshot?(stage) ->
        {:error, :snapshot_incomplete}

      not valid_channel_references?(stage) ->
        {:error, :invalid_channel_reference}

      true ->
        additions = Map.new(stage.users, fn {uid, user} -> {{origin, uid}, user} end)
        users = Map.merge(old_users_removed, additions)
        {nick_claims, nick_keys} = index_users(users)
        {old_channels, old_members, old_lists, old_invites} = discard_channel_origin(replica, origin)

        {:ok,
         %{
           replica
           | users: users,
             nick_keys: nick_keys,
             nick_claims: nick_claims,
             channels: Map.merge(old_channels, with_origin(stage.channels, origin)),
             members: Map.merge(old_members, with_origin(stage.members, origin)),
             lists: Map.merge(old_lists, with_origin(stage.lists, origin)),
             invites: Map.merge(old_invites, with_origin(stage.invites, origin)),
             usage: Map.put(replica.usage, origin, %{count: stage_count(stage), bytes: stage.bytes}),
             total_bytes: total_bytes,
             staged_bytes: replica.staged_bytes - stage.bytes,
             origins: Map.put(replica.origins, origin, %{epoch: stage.epoch, cursor: stage.cursor}),
             staging: Map.delete(replica.staging, origin)
         }}
    end
  end

  defp incomplete_snapshot?(stage) do
    map_size(stage.users) != stage.expected or
      map_size(stage.channels) != stage.expected_channels or
      map_size(stage.members) != stage.expected_members or
      map_size(stage.lists) != stage.expected_lists or
      map_size(stage.invites) != stage.expected_invites
  end

  defp stage_count(stage) do
    Enum.sum(Enum.map([:users, :channels, :members, :lists, :invites], &map_size(Map.fetch!(stage, &1))))
  end

  defp valid_channel_references?(stage) do
    channel_keys = Map.keys(stage.channels) |> MapSet.new()
    user_uids = Map.keys(stage.users) |> MapSet.new()

    Enum.all?(stage.members, fn {{channel_key, uid}, _entry} ->
      MapSet.member?(channel_keys, channel_key) and MapSet.member?(user_uids, uid)
    end) and
      Enum.all?(stage.lists, fn {{channel_key, _kind, _mask}, _entry} ->
        MapSet.member?(channel_keys, channel_key)
      end) and
      Enum.all?(stage.invites, fn {{channel_key, uid}, _entry} ->
        MapSet.member?(channel_keys, channel_key) and MapSet.member?(user_uids, uid)
      end)
  end

  defp finish_delta(replica, origin, delta) do
    with true <- length(delta.entries) == delta.expected,
         {:ok, candidate} <- apply_delta_entries(replica, origin, Enum.reverse(delta.entries)) do
      commit_delta(candidate, origin, delta)
    else
      false -> {:error, :delta_incomplete}
      error -> error
    end
  end

  defp apply_delta_entries(replica, origin, entries) do
    Enum.reduce_while(entries, {:ok, replica}, &reduce_delta_entry(&1, &2, origin))
  end

  defp reduce_delta_entry(entry, {:ok, candidate}, origin) do
    case apply_delta_entry(candidate, origin, entry) do
      {:ok, updated} -> {:cont, {:ok, updated}}
      error -> {:halt, error}
    end
  end

  defp commit_delta(candidate, origin, delta) do
    if valid_committed_channel_references?(candidate, origin) do
      {:ok,
       %{
         candidate
         | origins: put_cursor(candidate.origins, origin, delta.sequence),
           deltas: Map.delete(candidate.deltas, origin)
       }}
    else
      {:error, :invalid_channel_reference}
    end
  end

  defp apply_delta_entry(replica, origin, frame) do
    field = frame["field"]
    {field_atom, _expected, entry, key} = staged_channel_identity("snapshot_#{field}", %{field => frame["entry"]})
    entries = Map.fetch!(replica, field_atom)
    full_key = {origin, key}
    old_entry = Map.get(entries, full_key)
    new_entry = if frame["action"] == "remove", do: nil, else: entry

    entries =
      if frame["action"] == "remove",
        do: Map.delete(entries, full_key),
        else: Map.put(entries, full_key, entry)

    with {:ok, usage, total_bytes} <- reserve_usage(replica, origin, old_entry, new_entry) do
      {:ok, replica |> Map.put(field_atom, entries) |> Map.put(:usage, usage) |> Map.put(:total_bytes, total_bytes)}
    end
  end

  defp reserve_usage(replica, origin, old_entry, new_entry) do
    current = Map.fetch!(replica.usage, origin)
    old_count = if is_nil(old_entry), do: 0, else: 1
    new_count = if is_nil(new_entry), do: 0, else: 1
    old_bytes = if is_nil(old_entry), do: 0, else: :erlang.external_size(old_entry)
    new_bytes = if is_nil(new_entry), do: 0, else: :erlang.external_size(new_entry)
    updated = %{count: current.count - old_count + new_count, bytes: current.bytes - old_bytes + new_bytes}
    total_bytes = replica.total_bytes + updated.bytes - current.bytes

    cond do
      updated.count > Frame.max_snapshot_entries() or updated.bytes > replica.max_snapshot_bytes ->
        {:error, :origin_state_too_large}

      total_bytes + replica.staged_bytes > replica.max_network_bytes ->
        {:error, :network_state_too_large}

      true ->
        {:ok, Map.put(replica.usage, origin, updated), total_bytes}
    end
  end

  defp valid_committed_channel_references?(replica, origin) do
    channels = for {{^origin, key}, _entry} <- replica.channels, into: MapSet.new(), do: key
    users = for {{^origin, uid}, _entry} <- replica.users, into: MapSet.new(), do: uid

    members_valid? =
      Enum.all?(replica.members, fn
        {{^origin, {channel_key, uid}}, _entry} -> MapSet.member?(channels, channel_key) and MapSet.member?(users, uid)
        _other -> true
      end)

    lists_valid? =
      Enum.all?(replica.lists, fn
        {{^origin, {channel_key, _kind, _mask}}, _entry} -> MapSet.member?(channels, channel_key)
        _other -> true
      end)

    invites_valid? =
      Enum.all?(replica.invites, fn
        {{^origin, {channel_key, uid}}, _entry} -> MapSet.member?(channels, channel_key) and MapSet.member?(users, uid)
        _other -> true
      end)

    members_valid? and lists_valid? and invites_valid?
  end

  defp with_origin(entries, origin), do: Map.new(entries, fn {key, entry} -> {{origin, key}, entry} end)

  defp next_event?(replica, frame) do
    if Map.has_key?(replica.staging, frame["origin"]) or Map.has_key?(replica.deltas, frame["origin"]) do
      {:error, :snapshot_in_progress}
    else
      next_committed_event?(replica, frame)
    end
  end

  defp next_committed_event?(replica, frame) do
    incoming_epoch = frame["epoch"]
    incoming_sequence = frame["sequence"]

    case Map.fetch(replica.origins, frame["origin"]) do
      {:ok, %{epoch: ^incoming_epoch, cursor: cursor}} when incoming_sequence == cursor + 1 ->
        :ok

      {:ok, %{epoch: epoch}} when epoch != incoming_epoch ->
        {:error, :stale_epoch}

      {:ok, _origin} ->
        {:error, :sequence_gap}

      :error ->
        {:error, :snapshot_required}
    end
  end

  defp stale_snapshot?(nil, _frame), do: false

  defp stale_snapshot?(current, frame) do
    current.epoch == frame["epoch"] and current.cursor > frame["cursor"]
  end

  defp no_same_origin_nick_collision?(replica, origin, user) do
    nick_key = CaseMapping.normalize(user["nick"])
    identity = {origin, user["uid"]}

    if Enum.any?(Map.get(replica.nick_claims, nick_key, MapSet.new()), fn {home, uid} ->
         home == origin and {home, uid} != identity
       end),
       do: {:error, :nick_collision},
       else: :ok
  end

  defp stable_registration?(nil, _user), do: :ok

  defp stable_registration?(old_user, user) do
    if old_user["registered_at"] == user["registered_at"],
      do: :ok,
      else: {:error, :registration_changed}
  end

  defp put_cursor(origins, origin, sequence), do: put_in(origins, [origin, :cursor], sequence)

  defp discard_origin(users, origin), do: Map.reject(users, fn {{home, _uid}, _user} -> home == origin end)

  defp discard_channel_origin(replica, origin) do
    [replica.channels, replica.members, replica.lists, replica.invites]
    |> Enum.map(fn entries -> Map.reject(entries, fn {{home, _key}, _entry} -> home == origin end) end)
    |> List.to_tuple()
  end

  defp index_users(users) do
    claims = Enum.reduce(users, %{}, fn {identity, user}, acc -> add_claim(acc, identity, user) end)
    nick_keys = Map.new(claims, fn {nick, identities} -> {nick, winner(identities, users)} end)
    {claims, nick_keys}
  end

  defp add_claim(claims, identity, user) do
    key = CaseMapping.normalize(user["nick"])
    Map.update(claims, key, MapSet.new([identity]), &MapSet.put(&1, identity))
  end

  defp remove_claim(claims, _identity, nil), do: claims

  defp remove_claim(claims, identity, user) do
    key = CaseMapping.normalize(user["nick"])
    remaining = claims |> Map.get(key, MapSet.new()) |> MapSet.delete(identity)
    if MapSet.size(remaining) == 0, do: Map.delete(claims, key), else: Map.put(claims, key, remaining)
  end

  defp refresh_nicks(nick_keys, claims, users, user_versions) do
    user_versions
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&CaseMapping.normalize(&1["nick"]))
    |> Enum.uniq()
    |> Enum.reduce(nick_keys, fn key, acc ->
      case Map.get(claims, key) do
        nil -> Map.delete(acc, key)
        identities -> Map.put(acc, key, winner(identities, users))
      end
    end)
  end

  defp winner(identities, users) do
    Enum.min_by(identities, fn {origin, _uid} = identity ->
      NickAuthority.rank(NickAuthority.from_wire(origin, Map.fetch!(users, identity)))
    end)
  end
end
