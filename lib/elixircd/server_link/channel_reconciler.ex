defmodule ElixIRCd.ServerLink.ChannelReconciler do
  @moduledoc "Aligns local channel metadata with the selected committed network creation."

  alias ElixIRCd.Commands.Mode.ChannelModes
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelExcepts
  alias ElixIRCd.Repositories.ChannelInvexes
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.Tables.ChannelIdentity

  @doc "Applies selected metadata and older creation identities after replica commit."
  @spec reconcile(map(), map(), String.t()) :: %{String.t() => [map()]}
  def reconcile(previous_views, current_views, local_id) do
    changed =
      current_views
      |> Enum.filter(fn {key, view} ->
        view.origin != local_id and selected_metadata(Map.get(previous_views, key)) != selected_metadata(view)
      end)

    changes =
      if changed == [],
        do: [],
        else: Memento.transaction!(fn -> Enum.flat_map(changed, &reconcile_one(&1, local_id)) end)

    Enum.each(changes, &announce_change/1)

    Map.new(changes, fn change -> {change.key, change.prior_memberships} end)
    |> Map.reject(fn {_key, memberships} -> is_nil(memberships) end)
  end

  defp selected_metadata(nil), do: nil
  defp selected_metadata(view), do: {view.origin, view.channel}

  defp reconcile_one({key, view}, local_id) do
    with {:ok, channel} <- Channels.get_by_name(key),
         {:ok, attrs} <- ChannelPayload.to_local(view.channel) do
      creator = local_creator(key, local_id)

      cond do
        same_identity?(channel, creator, attrs) -> update_aligned(channel, attrs)
        older_identity?(attrs, channel, creator) -> replace_losing_identity(channel, attrs)
        true -> []
      end
    else
      _ -> []
    end
  end

  defp local_creator(key, local_id) do
    case Memento.Query.read(ChannelIdentity, key) do
      %ChannelIdentity{creator: creator} -> creator
      nil -> local_id
    end
  end

  defp same_identity?(channel, creator, attrs),
    do: creator == attrs.creator and DateTime.compare(channel.created_at, attrs.created_at) == :eq

  defp older_identity?(attrs, channel, creator) do
    {DateTime.to_unix(attrs.created_at, :microsecond), attrs.creator} <
      {DateTime.to_unix(channel.created_at, :microsecond), creator}
  end

  defp update_aligned(channel, attrs) do
    updated = Map.take(attrs, [:name, :modes, :topic])
    modes_changed? = MapSet.new(channel.modes) != MapSet.new(updated.modes)
    topic_changed? = not same_topic?(channel.topic, updated.topic)

    if channel.name != updated.name or modes_changed? or topic_changed? do
      Channels.update(channel, updated)
      [change(channel, attrs, [], [], nil)]
    else
      []
    end
  end

  defp replace_losing_identity(channel, attrs) do
    key = channel.name_key
    prior_memberships = UserChannels.get_by_channel_name(key)
    demoted = prior_memberships |> Enum.flat_map(&demote_local_member/1) |> Enum.sort()
    removed_lists = remove_local_lists(key)

    ChannelInvites.delete_by_channel_name(channel.name)
    Channels.update(channel, Map.take(attrs, [:name, :created_at, :modes, :topic]))
    Memento.Query.write(ChannelIdentity.new(key, attrs.creator))
    [change(channel, attrs, demoted, removed_lists, prior_memberships)]
  end

  defp demote_local_member(%{modes: []}), do: []

  defp demote_local_member(membership) do
    UserChannels.update(membership, %{modes: []})

    case Users.get_by_pid(membership.user_pid) do
      {:ok, user} -> Enum.map(membership.modes, &{&1, user.nick})
      {:error, :user_not_found} -> []
    end
  end

  defp remove_local_lists(key) do
    [{ChannelBans, :b}, {ChannelExcepts, :e}, {ChannelInvexes, :I}]
    |> Enum.flat_map(fn {repository, mode} ->
      repository.get_by_channel_name_key(key)
      |> Enum.map(fn entry ->
        repository.delete(entry)
        {mode, entry.mask}
      end)
    end)
    |> Enum.sort()
  end

  defp change(channel, attrs, demoted, removed_lists, prior_memberships) do
    %{
      key: channel.name_key,
      name: attrs.name,
      old_modes: channel.modes,
      new_modes: attrs.modes,
      topic: if(same_topic?(channel.topic, attrs.topic), do: :unchanged, else: {:changed, attrs.topic}),
      demoted: demoted,
      removed_lists: removed_lists,
      prior_memberships: prior_memberships
    }
  end

  defp announce_change(change) do
    recipients =
      Memento.transaction!(fn ->
        change.name
        |> UserChannels.get_by_channel_name()
        |> Enum.map(& &1.user_pid)
        |> Users.get_by_pids()
      end)

    mode_changes = mode_changes(change.old_modes, change.new_modes)

    Enum.each(change.demoted, fn {mode, nick} ->
      %Message{command: "MODE", params: [change.name, "-#{mode}", nick]}
      |> Dispatcher.broadcast_without_history(:server, recipients)
    end)

    Enum.each(change.removed_lists, fn {mode, mask} ->
      %Message{command: "MODE", params: [change.name, "-#{mode}", mask]}
      |> Dispatcher.broadcast_without_history(:server, recipients)
    end)

    if mode_changes != [] do
      %Message{command: "MODE", params: [change.name, ChannelModes.display_mode_changes(mode_changes)]}
      |> Dispatcher.broadcast_without_history(:server, recipients)
    end

    case change.topic do
      {:changed, topic} ->
        text = if is_nil(topic), do: "", else: topic.text

        %Message{command: "TOPIC", params: [change.name], trailing: text}
        |> Dispatcher.broadcast_without_history(:server, recipients)

      :unchanged ->
        :ok
    end
  end

  defp mode_changes(old_modes, new_modes) do
    removed = old_modes |> Enum.reject(&(&1 in new_modes)) |> Enum.map(&{:remove, mode_name(&1)})
    added = new_modes |> Enum.reject(&(&1 in old_modes)) |> Enum.map(&{:add, &1})
    removed ++ added
  end

  defp mode_name({mode, _value}), do: mode
  defp mode_name(mode), do: mode

  defp same_topic?(nil, nil), do: true

  defp same_topic?(left, right) when not is_nil(left) and not is_nil(right) do
    left.text == right.text and left.setter == right.setter and DateTime.compare(left.set_at, right.set_at) == :eq
  end

  defp same_topic?(_left, _right), do: false
end
