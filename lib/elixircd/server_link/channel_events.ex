defmodule ElixIRCd.ServerLink.ChannelEvents do
  @moduledoc "Delivers committed remote membership changes to local channel clients."

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelExcepts
  alias ElixIRCd.Repositories.ChannelInvexes
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Protocol

  defmodule ListChange do
    @moduledoc "One visible change to a network channel mask list."

    @enforce_keys [:action, :kind, :mask]
    defstruct [:action, :kind, :mask]

    @type t :: %__MODULE__{action: :add | :remove, kind: String.t(), mask: String.t()}
  end

  @doc "Emits JOIN, PART and status MODE after an atomic remote channel delta commits."
  @spec deliver_delta(map(), map(), String.t(), map(), map(), map()) :: :ok
  def deliver_delta(previous, current, origin, previous_views, current_views, prior_memberships \\ %{}) do
    keys = changed_members(previous, current, origin)
    list_keys = changed_list_channels(previous.deltas[origin].entries)

    deliver_keys(keys, previous, current, previous_views, current_views, prior_memberships)
    deliver_list_changes(list_keys, previous_views, current_views)
  end

  @doc "Emits membership changes after a complete remote snapshot replaces committed state."
  @spec deliver_snapshot(map(), map(), String.t(), map(), map(), map()) :: :ok
  def deliver_snapshot(previous, current, origin, previous_views, current_views, prior_memberships \\ %{}) do
    changed_channels =
      (Map.keys(previous.channels) ++ Map.keys(current.channels))
      |> Enum.filter(fn {home, _channel_key} -> home == origin end)
      |> MapSet.new(&elem(&1, 1))

    keys =
      (Map.keys(previous.members) ++ Map.keys(current.members))
      |> Enum.filter(fn {home, {channel_key, _uid}} ->
        home == origin or MapSet.member?(changed_channels, channel_key)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    list_channels = MapSet.union(changed_channels, snapshot_list_channels(previous, current, origin))

    deliver_keys(keys, previous, current, previous_views, current_views, prior_memberships)
    deliver_list_changes(list_channels, previous_views, current_views)
  end

  @doc "Announces effective remote list changes when a route disappears or is replaced."
  @spec deliver_route_lists(map(), map()) :: :ok
  def deliver_route_lists(previous_views, current_views) do
    keys = MapSet.new(Map.keys(previous_views) ++ Map.keys(current_views))
    deliver_list_changes(keys, previous_views, current_views)
  end

  defp snapshot_list_channels(previous, current, origin) do
    (Map.keys(previous.lists) ++ Map.keys(current.lists))
    |> Enum.filter(fn {home, _entry_key} -> home == origin end)
    |> MapSet.new(fn {_home, {channel_key, _kind, _mask_key}} -> channel_key end)
  end

  defp changed_list_channels(entries) do
    for %{"field" => field, "entry" => entry} <- entries,
        field in ["list", "channel"],
        into: MapSet.new(),
        do: CaseMapping.normalize(if(field == "channel", do: entry["name"], else: entry["channel"]))
  end

  defp deliver_list_changes(keys, previous_views, current_views) do
    keys
    |> Enum.sort()
    |> Enum.each(fn key ->
      old = effective_remote_lists(Map.get(previous_views, key))
      current = effective_remote_lists(Map.get(current_views, key))

      changes =
        list_differences(old, current, :remove) ++ list_differences(current, old, :add)

      if changes != [], do: announce_list_changes(key, changes)
    end)

    :ok
  end

  defp announce_list_changes(key, changes) do
    case local_recipients(key) do
      {:ok, channel, _memberships, recipients} ->
        local = local_list_keys(key)
        Enum.each(changes, &send_list_change(&1, channel.name, local, recipients))

      :error ->
        :ok
    end
  end

  defp effective_remote_lists(nil), do: %{}

  defp effective_remote_lists(view) do
    view.remote_lists
    |> Enum.filter(& &1.effective)
    |> Map.new(fn record ->
      entry = record.entry
      {{entry["kind"], Protocol.mask_key(entry["mask"])}, entry["mask"]}
    end)
  end

  defp list_differences(source, other, action) do
    source
    |> Enum.reject(fn {key, _mask} -> Map.has_key?(other, key) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {{kind, _key}, mask} -> %ListChange{action: action, kind: kind, mask: mask} end)
  end

  defp local_list_keys(key) do
    Memento.transaction!(fn ->
      [{ChannelBans, "b"}, {ChannelExcepts, "e"}, {ChannelInvexes, "I"}]
      |> Enum.flat_map(fn {repository, kind} ->
        Enum.map(repository.get_by_channel_name_key(key), &{kind, &1.mask_key})
      end)
      |> MapSet.new()
    end)
  end

  defp send_list_change(%ListChange{kind: kind, mask: mask, action: action}, channel, local, recipients) do
    key = {kind, Protocol.mask_key(mask)}

    unless MapSet.member?(local, key) do
      sign = if action == :add, do: "+", else: "-"

      %Message{command: "MODE", params: [channel, sign <> kind, mask]}
      |> Dispatcher.broadcast_without_history(:server, recipients)
    end
  end

  @doc "Reconciles remote member visibility after a committed local channel metadata delta."
  @spec deliver_local_delta(map(), map(), map(), [map()]) :: :ok
  def deliver_local_delta(replica, previous_views, current_views, frames) do
    changed_channels =
      for %{"type" => "delta_entry", "field" => "channel", "entry" => entry} <- frames,
          into: MapSet.new(),
          do: CaseMapping.normalize(entry["name"])

    replica.members
    |> Map.keys()
    |> Enum.filter(fn {_origin, {channel_key, _uid}} -> MapSet.member?(changed_channels, channel_key) end)
    |> Enum.sort()
    |> Enum.each(fn {origin, {channel_key, uid}} ->
      deliver_status_change(previous_views, current_views, origin, channel_key, uid, replica)
    end)

    :ok
  end

  defp deliver_keys(keys, previous, current, previous_views, current_views, prior_memberships) do
    Enum.each(keys, &deliver_member_change(&1, previous, current, previous_views, current_views, prior_memberships))

    :ok
  end

  defp deliver_member_change(
         {origin, {channel_key, uid}} = identity,
         previous,
         current,
         old_views,
         new_views,
         prior_memberships
       ) do
    old_member = Map.get(previous.members, identity)
    new_member = Map.get(current.members, identity)

    cond do
      is_nil(old_member) and not is_nil(new_member) ->
        deliver_join(current, origin, channel_key, uid, new_views)

      not is_nil(old_member) and is_nil(new_member) ->
        kick = kick_for_delta(previous, origin, channel_key, uid)
        maybe_deliver_part(previous, current, origin, channel_key, uid, old_views, prior_memberships, kick)

      replaced_membership?(old_member, new_member) ->
        kick = kick_for_delta(previous, origin, channel_key, uid)
        maybe_deliver_part(previous, current, origin, channel_key, uid, old_views, prior_memberships, kick)
        deliver_join(current, origin, channel_key, uid, new_views)

      member_status_changed?(old_member, new_member, old_views, new_views, origin, channel_key, uid) ->
        deliver_status_change(old_views, new_views, origin, channel_key, uid, current, prior_memberships)

      true ->
        :ok
    end
  end

  defp replaced_membership?(old_member, new_member) when is_map(old_member) and is_map(new_member),
    do: old_member["joined_at"] != new_member["joined_at"]

  defp replaced_membership?(_old_member, _new_member), do: false

  defp maybe_deliver_part(previous, current, origin, channel_key, uid, old_views, prior_memberships, kick) do
    if Map.has_key?(current.users, {origin, uid}),
      do: deliver_part(previous, origin, channel_key, uid, old_views, prior_memberships, kick)
  end

  defp kick_for_delta(replica, origin, channel_key, uid) do
    case Map.get(replica.deltas, origin) do
      %{entries: entries} ->
        Enum.find_value(entries, &matching_kick(&1, channel_key, uid))

      _ ->
        nil
    end
  end

  defp matching_kick(%{"field" => "member", "action" => "remove", "entry" => entry, "kick" => kick}, key, uid) do
    if CaseMapping.normalize(entry["channel"]) == key and entry["uid"] == uid, do: kick
  end

  defp matching_kick(_entry, _key, _uid), do: nil

  defp member_status_changed?(old_member, new_member, old_views, new_views, origin, channel_key, uid) do
    old_view = Map.get(old_views, channel_key)
    new_view = Map.get(new_views, channel_key)

    old_member != new_member or selected_channel_changed?(old_view, new_view) or
      effective_modes(old_view, origin, uid) != effective_modes(new_view, origin, uid) or
      auditorium?(old_view) != auditorium?(new_view)
  end

  defp selected_channel_changed?(nil, nil), do: false
  defp selected_channel_changed?(nil, _new), do: true
  defp selected_channel_changed?(_old, nil), do: true
  defp selected_channel_changed?(old, new), do: old.channel != new.channel

  @doc "Finds real local clients who can see a remote member in committed channel views."
  @spec local_audience(map(), String.t(), String.t()) :: [map()]
  def local_audience(views, origin, uid) do
    views
    |> Enum.flat_map(&audience_for_view(&1, origin, uid))
    |> Enum.uniq_by(& &1.pid)
  end

  defp audience_for_view({channel_key, view}, origin, uid) do
    member = Enum.find(view.remote_members, &(&1.origin == origin and &1.member["uid"] == uid))

    with %{effective_modes: modes} <- member,
         {:ok, channel, memberships, recipients} <- local_recipients(channel_key) do
      visible_recipients(recipients, memberships, channel.modes, view, modes)
    else
      _ -> []
    end
  end

  defp changed_members(previous, current, origin) do
    entries = previous.deltas[origin].entries

    member_keys =
      for %{"field" => "member", "entry" => entry} <- entries,
          do: {origin, {CaseMapping.normalize(entry["channel"]), entry["uid"]}}

    changed_channels =
      for %{"field" => "channel", "entry" => entry} <- entries,
          into: MapSet.new(),
          do: CaseMapping.normalize(entry["name"])

    metadata_member_keys =
      if MapSet.size(changed_channels) == 0 do
        []
      else
        (Map.keys(previous.members) ++ Map.keys(current.members))
        |> Enum.filter(fn {_home, {channel_key, _uid}} ->
          MapSet.member?(changed_channels, channel_key)
        end)
      end

    (member_keys ++ metadata_member_keys) |> Enum.uniq() |> Enum.sort()
  end

  defp deliver_join(replica, origin, channel_key, uid, views) do
    with {:ok, sender} <- Map.fetch(replica.users, {origin, uid}),
         {:ok, channel, memberships, recipients} <- local_recipients(channel_key),
         {:ok, view} <- Map.fetch(views, channel_key) do
      modes = effective_modes(view, origin, uid)
      recipients = visible_recipients(recipients, memberships, channel.modes, view, modes)
      prefix = sender |> UserPayload.public_view() |> Protocol.user_mask()
      send_join_messages(sender, channel.name, prefix, recipients)
      send_status_messages(channel.name, sender["nick"], [], modes, recipients)
    end

    :ok
  end

  defp deliver_part(replica, origin, channel_key, uid, views, prior_memberships, kick) do
    with {:ok, sender} <- Map.fetch(replica.users, {origin, uid}),
         {:ok, channel, memberships, recipients} <- local_recipients(channel_key),
         {:ok, view} <- Map.fetch(views, channel_key) do
      modes = effective_modes(view, origin, uid)
      old_memberships = Map.get(prior_memberships, channel_key, memberships)
      recipients = visible_recipients(recipients, old_memberships, [], view, modes)
      prefix = sender |> UserPayload.public_view() |> Protocol.user_mask()

      send_member_departure(channel.name, sender["nick"], prefix, kick, recipients)
    end

    :ok
  end

  defp send_member_departure(channel, _nick, prefix, nil, recipients),
    do: send_part_message(channel, prefix, recipients)

  defp send_member_departure(channel, nick, _prefix, kick, recipients) do
    %Message{command: "KICK", params: [channel, nick], trailing: kick["reason"], prefix: kick["actor_mask"]}
    |> Dispatcher.broadcast_without_history(nil, recipients)
  end

  defp deliver_status_change(previous_views, current_views, origin, channel_key, uid, replica, prior_memberships \\ %{}) do
    with {:ok, sender} <- Map.fetch(replica.users, {origin, uid}),
         {:ok, channel, memberships, recipients} <- local_recipients(channel_key),
         {:ok, old_view} <- Map.fetch(previous_views, channel_key),
         {:ok, new_view} <- Map.fetch(current_views, channel_key) do
      old_modes = effective_modes(old_view, origin, uid)
      new_modes = effective_modes(new_view, origin, uid)
      old_memberships = Map.get(prior_memberships, channel_key, memberships)
      old_visible = visible_recipients(recipients, old_memberships, [], old_view, old_modes)
      new_visible = visible_recipients(recipients, memberships, [], new_view, new_modes)
      old_pids = MapSet.new(old_visible, & &1.pid)
      new_pids = MapSet.new(new_visible, & &1.pid)
      joined = Enum.reject(new_visible, &MapSet.member?(old_pids, &1.pid))
      parted = Enum.reject(old_visible, &MapSet.member?(new_pids, &1.pid))
      prefix = sender |> UserPayload.public_view() |> Protocol.user_mask()

      send_join_messages(sender, channel.name, prefix, joined)

      send_status_messages(
        channel.name,
        sender["nick"],
        old_modes,
        new_modes,
        Enum.uniq_by(old_visible ++ new_visible, & &1.pid)
      )

      send_part_message(channel.name, prefix, parted)
    end

    :ok
  end

  defp send_part_message(channel_name, prefix, recipients) do
    %Message{command: "PART", params: [channel_name], prefix: prefix}
    |> Dispatcher.broadcast_without_history(nil, recipients)
  end

  defp local_recipients(channel_key) do
    Memento.transaction!(fn ->
      case Channels.get_by_name(channel_key) do
        {:ok, channel} ->
          memberships = UserChannels.get_by_channel_name(channel.name)
          pids = Enum.map(memberships, & &1.user_pid)
          {:ok, channel, memberships, Users.get_by_pids(pids)}

        _ ->
          :error
      end
    end)
  end

  defp visible_recipients(recipients, memberships, local_modes, view, actor_modes) do
    selected_modes = Enum.map(view.channel["modes"], & &1["name"])

    if (:u in local_modes or "u" in local_modes or "u" in selected_modes) and not privileged?(actor_modes) do
      privileged_pids =
        memberships
        |> Enum.filter(&privileged?(&1.modes))
        |> MapSet.new(& &1.user_pid)

      Enum.filter(recipients, &MapSet.member?(privileged_pids, &1.pid))
    else
      recipients
    end
  end

  defp send_join_messages(sender, channel_name, prefix, recipients) do
    {extended, standard} = Enum.split_with(recipients, &("extended-join" in &1.capabilities))

    %Message{command: "JOIN", params: [channel_name], prefix: prefix}
    |> Dispatcher.broadcast_without_history(nil, standard)

    %Message{
      command: "JOIN",
      params: [channel_name, sender["account"] || "*"],
      trailing: sender["realname"],
      prefix: prefix
    }
    |> Dispatcher.broadcast_without_history(nil, extended)

    if sender["away"] do
      watchers = Enum.filter(recipients, &("away-notify" in &1.capabilities))

      %Message{command: "AWAY", params: [], trailing: sender["away"], prefix: prefix}
      |> Dispatcher.broadcast_without_history(nil, watchers)
    end
  end

  defp send_status_messages(channel_name, nick, old_modes, new_modes, recipients) do
    Enum.each(["o", "v"], &send_one_status(&1, channel_name, nick, old_modes, new_modes, recipients))

    :ok
  end

  defp send_one_status(mode, channel_name, nick, old_modes, new_modes, recipients) do
    if mode in old_modes != mode in new_modes do
      sign = if mode in new_modes, do: "+", else: "-"

      %Message{command: "MODE", params: [channel_name, sign <> mode, nick]}
      |> Dispatcher.broadcast_without_history(:server, recipients)
    end
  end

  defp effective_modes(nil, _origin, _uid), do: []

  defp effective_modes(view, origin, uid) do
    Enum.find_value(view.remote_members, [], fn member ->
      if member.origin == origin and member.member["uid"] == uid, do: member.effective_modes
    end)
  end

  defp auditorium?(nil), do: false
  defp auditorium?(view), do: Enum.any?(view.channel["modes"], &(&1["name"] == "u"))

  defp privileged?(modes), do: "o" in modes or "v" in modes or :o in modes or :v in modes
end
