defmodule ElixIRCd.Commands.Rename do
  @moduledoc "Atomically renames a channel and all local persistent references."

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [channel_name?: 1, user_reply: 1]

  alias ElixIRCd.Commands.Join
  alias ElixIRCd.History
  alias ElixIRCd.Message
  alias ElixIRCd.Metadata
  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelExcepts
  alias ElixIRCd.Repositories.ChannelInvexes
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.ChatHistory
  alias ElixIRCd.Repositories.ReadMarkers
  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.StandardReply
  alias ElixIRCd.Utils.CaseMapping

  @impl true
  def handle(user, %{params: [old_name, new_name, reason], trailing: nil} = message),
    do: handle(user, %{message | params: [old_name, new_name], trailing: reason})

  def handle(user, %{params: [old_name, new_name], trailing: reason}) do
    with :ok <- available(user),
         :ok <- validate_name(new_name),
         {:ok, channel} <- Channels.get_by_name(old_name),
         :ok <- ensure_destination_free(channel, new_name),
         {:ok, membership} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, old_name),
         true <- :o in membership.modes,
         :ok <- validate_reason(reason) do
      users = channel.name |> UserChannels.get_by_channel_name() |> Enum.map(& &1.user_pid) |> Users.get_by_pids()
      renamed_channel = rename_channel(channel, new_name)

      History.record_channel_event(
        %Message{command: "RENAME", params: [channel.name, new_name], trailing: reason || ""},
        user,
        new_name
      )

      relay_rename(user, users, renamed_channel, channel.name, reason)
    else
      {:error, :name_in_use} ->
        fail(user, "CHANNEL_NAME_IN_USE", [old_name, new_name], "Channel name is already in use")

      {:error, :channel_not_found} ->
        numeric_error(user, :err_nosuchchannel, old_name, "No such channel")

      {:error, :user_channel_not_found} ->
        numeric_error(user, :err_notonchannel, old_name, "You're not on that channel")

      {:error, :invalid_name} ->
        fail(user, "CANNOT_RENAME", [old_name, new_name], "Invalid channel name")

      {:error, :invalid_reason} ->
        fail(user, "CANNOT_RENAME", [old_name, new_name], "Rename reason is too long")

      {:error, :unavailable} ->
        fail(user, "CANNOT_RENAME", [old_name, new_name], "Channel renaming is unavailable")

      false ->
        numeric_error(user, :err_chanoprivsneeded, old_name, "You're not channel operator")
    end
  end

  def handle(user, %{params: [old_name, new_name | _]}) do
    fail(user, "INVALID_PARAMS", [old_name, new_name], "Too many RENAME parameters")
  end

  def handle(user, _message) do
    %Message{command: :err_needmoreparams, params: [user_reply(user), "RENAME"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp available(_user) do
    config = Application.fetch_env!(:elixircd, :channel_rename)
    if config[:enabled], do: :ok, else: {:error, :unavailable}
  end

  defp ensure_destination_free(channel, new_name) do
    if channel.name_key == CaseMapping.normalize(new_name) do
      :ok
    else
      case Channels.get_by_name(new_name) do
        {:error, :channel_not_found} -> :ok
        {:ok, _channel} -> {:error, :name_in_use}
      end
    end
  end

  defp validate_name(name) do
    max_length = Application.fetch_env!(:elixircd, :channel)[:max_channel_name_length]

    if channel_name?(name) and String.length(name) <= max_length and not String.contains?(name, [" ", ",", "\a"]),
      do: :ok,
      else: {:error, :invalid_name}
  end

  defp validate_reason(nil), do: :ok

  defp validate_reason(reason) do
    if String.length(reason) <= Application.fetch_env!(:elixircd, :channel_rename)[:max_reason_length],
      do: :ok,
      else: {:error, :invalid_reason}
  end

  defp rename_channel(channel, new_name) do
    old_key = channel.name_key
    new_key = CaseMapping.normalize(new_name)
    renamed = %{channel | name_key: new_key, name: new_name}

    Channels.replace(channel, renamed)
    migrate_memberships(old_key, new_key)
    migrate_bans(old_key, new_key)
    migrate_excepts(old_key, new_key)
    migrate_invexes(old_key, new_key)
    migrate_invites(old_key, new_key)
    migrate_registered_channel(old_key, new_key, new_name)
    migrate_registered_access(old_key, new_key)
    migrate_history(old_key, new_key, new_name)
    migrate_read_markers(old_key, new_key, new_name)
    Metadata.rename_channel(old_key, new_key)
    renamed
  end

  defp migrate_memberships(old_key, new_key) do
    Enum.each(UserChannels.get_by_channel_name(old_key), fn record ->
      UserChannels.update(record, %{channel_name_key: new_key})
    end)
  end

  defp migrate_bans(old_key, new_key) do
    Enum.each(ChannelBans.get_by_channel_name_key(old_key), fn record ->
      ChannelBans.replace(record, %{record | channel_name_key: new_key})
    end)
  end

  defp migrate_excepts(old_key, new_key) do
    Enum.each(ChannelExcepts.get_by_channel_name_key(old_key), fn record ->
      ChannelExcepts.replace(record, %{record | channel_name_key: new_key})
    end)
  end

  defp migrate_invexes(old_key, new_key) do
    Enum.each(ChannelInvexes.get_by_channel_name_key(old_key), fn record ->
      ChannelInvexes.replace(record, %{record | channel_name_key: new_key})
    end)
  end

  defp migrate_invites(old_key, new_key) do
    Enum.each(ChannelInvites.get_by_channel_name_key(old_key), fn record ->
      ChannelInvites.replace(record, %{record | channel_name_key: new_key})
    end)
  end

  defp migrate_registered_channel(old_key, new_key, new_name) do
    case RegisteredChannels.get_by_name(old_key) do
      {:error, :registered_channel_not_found} -> :ok
      {:ok, record} -> RegisteredChannels.replace(record, %{record | name_key: new_key, name: new_name})
    end
  end

  defp migrate_registered_access(old_key, new_key) do
    Enum.each(RegisteredChannelAccesses.get_by_channel_name(old_key), fn record ->
      updated = %{record | id: {new_key, record.account_name_key}, channel_name_key: new_key}
      RegisteredChannelAccesses.replace(record, updated)
    end)
  end

  defp migrate_history(old_key, new_key, new_name) do
    old_target = "channel:" <> old_key
    new_target = "channel:" <> new_key

    Enum.each(ChatHistory.for_target(old_target), fn record ->
      {_old_target, timestamp, msgid} = record.id
      message = rewrite_history_message(record.message, old_key, new_name)

      updated = %{
        record
        | id: {new_target, timestamp, msgid},
          target_key: new_target,
          target_name: new_name,
          message: message
      }

      ChatHistory.replace(record, updated)
    end)
  end

  defp migrate_read_markers(old_key, new_key, new_name) do
    Enum.each(ReadMarkers.get_by_target_key(old_key), fn record ->
      updated = %{record | id: {record.owner_key, new_key}, target_key: new_key, target: new_name}
      ReadMarkers.replace(record, updated)
    end)
  end

  defp rewrite_history_message(%Message{params: [target | rest]} = message, old_key, new_name) do
    if channel_name?(target) and CaseMapping.normalize(target) == old_key,
      do: %{message | params: [new_name | rest]},
      else: message
  end

  defp rewrite_history_message(%{kind: :multiline, target: target, lines: lines} = message, old_key, new_name) do
    if channel_name?(target) and CaseMapping.normalize(target) == old_key do
      %{message | target: new_name, lines: Enum.map(lines, &rewrite_history_message(&1, old_key, new_name))}
    else
      message
    end
  end

  defp rewrite_history_message(message, _old_key, _new_name), do: message

  defp relay_rename(actor, users, renamed_channel, old_name, reason) do
    {modern, legacy} = Enum.split_with(users, &("draft/channel-rename" in &1.capabilities))
    new_name = renamed_channel.name
    rename = %Message{command: "RENAME", params: [old_name, new_name], trailing: reason || ""}
    Dispatcher.broadcast(rename, actor, modern)

    unless renamed_channel.name_key == CaseMapping.normalize(old_name) do
      memberships = UserChannels.get_by_channel_name(new_name)

      Enum.each(legacy, fn recipient ->
        Dispatcher.broadcast_without_history(
          %Message{command: "PART", params: [old_name], trailing: reason || "Channel renamed"},
          recipient,
          recipient
        )

        Dispatcher.broadcast_without_history(%Message{command: "JOIN", params: [new_name]}, recipient, recipient)
        Metadata.sync_join(recipient, renamed_channel, users)

        Join.channel_state_messages(recipient, renamed_channel, memberships)
        |> Dispatcher.broadcast(:server, recipient)
      end)
    end

    :ok
  end

  defp fail(user, code, context, description) do
    %StandardReply{type: :fail, command: "RENAME", code: code, context: List.wrap(context), description: description}
    |> Dispatcher.broadcast(:server, user)
  end

  defp numeric_error(user, code, channel, description) do
    %Message{command: code, params: [user_reply(user), channel], trailing: description}
    |> Dispatcher.broadcast(:server, user)
  end
end
