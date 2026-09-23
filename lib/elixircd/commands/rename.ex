defmodule ElixIRCd.Commands.Rename do
  @moduledoc "Atomically renames a channel and all local persistent references."

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [channel_name?: 1]

  alias ElixIRCd.History
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.StandardReply
  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Tables.ChannelExcept
  alias ElixIRCd.Tables.ChannelInvex
  alias ElixIRCd.Tables.ChannelListTombstone
  alias ElixIRCd.Tables.ChannelInvite
  alias ElixIRCd.Tables.ChatHistory
  alias ElixIRCd.Tables.ReadMarker
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.RegisteredChannelAccess
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.CaseMapping

  @impl true
  def handle(user, %{params: [old_name, new_name | _], trailing: reason}) do
    with :ok <- available(user),
         :ok <- validate_name(new_name),
         {:ok, channel} <- Channels.get_by_name(old_name),
         {:error, :channel_not_found} <- Channels.get_by_name(new_name),
         {:ok, membership} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, old_name),
         true <- :o in membership.modes,
         :ok <- validate_reason(reason) do
      users = channel.name |> UserChannels.get_by_channel_name() |> Enum.map(& &1.user_pid) |> Users.get_by_pids()
      rename_channel(channel, new_name)

      History.record_channel_event(
        %Message{command: "RENAME", params: [channel.name, new_name], trailing: reason},
        user,
        new_name
      )

      relay_rename(user, users, channel.name, new_name, reason)
    else
      {:ok, _channel} -> fail(user, "CHANNEL_NAME_IN_USE", new_name, "Channel name is already in use")
      {:error, :channel_not_found} -> fail(user, "INVALID_CHANNEL", old_name, "No such channel")
      {:error, :user_channel_not_found} -> fail(user, "RENAME_NOT_ALLOWED", old_name, "You are not on that channel")
      {:error, :invalid_name} -> fail(user, "INVALID_CHANNEL", new_name, "Invalid channel name")
      {:error, :invalid_reason} -> fail(user, "INVALID_PARAMS", old_name, "Rename reason is too long")
      {:error, :unavailable} -> fail(user, "NEED_CAP", old_name, "Channel rename capability is required")
      false -> fail(user, "RENAME_NOT_ALLOWED", old_name, "Channel operator privileges are required")
    end
  end

  def handle(user, _message), do: fail(user, "INVALID_PARAMS", "*", "RENAME requires old and new channel names")

  defp available(user) do
    config = Application.fetch_env!(:elixircd, :channel_rename)
    if config[:enabled] and "draft/channel-rename" in user.capabilities, do: :ok, else: {:error, :unavailable}
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
    old_history_key = "channel:" <> old_key
    new_history_key = "channel:" <> new_key

    Memento.Query.delete_record(channel)
    %{channel | name_key: new_key, name: new_name} |> Memento.Query.write()

    migrate_channel_key(UserChannel, old_key, new_key, fn record -> %{record | channel_name_key: new_key} end)
    migrate_channel_key(ChannelBan, old_key, new_key, fn record -> %{record | channel_name_key: new_key} end)
    migrate_channel_key(ChannelExcept, old_key, new_key, fn record -> %{record | channel_name_key: new_key} end)
    migrate_channel_key(ChannelInvex, old_key, new_key, fn record -> %{record | channel_name_key: new_key} end)

    migrate_channel_key(ChannelListTombstone, old_key, new_key, fn record ->
      %{record | id: {new_key, record.mode, record.mask}, channel_name_key: new_key}
    end)

    migrate_channel_key(ChannelInvite, old_key, new_key, fn record -> %{record | channel_name_key: new_key} end)
    migrate_registered_channel(old_key, new_key, new_name)
    migrate_registered_access(old_key, new_key)
    migrate_history(old_history_key, new_history_key, new_name)
    migrate_read_markers(old_key, new_key, new_name)
    ElixIRCd.Metadata.rename_channel(old_key, new_key)
    :ok
  end

  defp migrate_channel_key(table, old_key, _new_key, transform) do
    table
    |> Memento.Query.all()
    |> Enum.filter(&(&1.channel_name_key == old_key))
    |> Enum.each(fn record ->
      Memento.Query.delete_record(record)
      record |> transform.() |> Memento.Query.write()
    end)
  end

  defp migrate_registered_channel(old_key, new_key, new_name) do
    case Memento.Query.read(RegisteredChannel, old_key) do
      nil ->
        :ok

      record ->
        Memento.Query.delete_record(record)
        %{record | name_key: new_key, name: new_name} |> Memento.Query.write()
    end
  end

  defp migrate_registered_access(old_key, new_key) do
    RegisteredChannelAccess
    |> Memento.Query.all()
    |> Enum.filter(&(&1.channel_name_key == old_key))
    |> Enum.each(fn record ->
      Memento.Query.delete_record(record)
      %{record | id: {new_key, record.account_name_key}, channel_name_key: new_key} |> Memento.Query.write()
    end)
  end

  defp migrate_history(old_key, new_key, new_name) do
    old_channel_key = String.replace_prefix(old_key, "channel:", "")

    ChatHistory
    |> Memento.Query.all()
    |> Enum.filter(&(&1.target_key == old_key))
    |> Enum.each(fn record ->
      Memento.Query.delete_record(record)
      {_old_target, timestamp, msgid} = record.id
      message = rewrite_history_message(record.message, old_channel_key, new_name)

      %{record | id: {new_key, timestamp, msgid}, target_key: new_key, target_name: new_name, message: message}
      |> Memento.Query.write()
    end)
  end

  defp migrate_read_markers(old_key, new_key, new_name) do
    ReadMarker
    |> Memento.Query.all()
    |> Enum.filter(&(&1.target_key == old_key))
    |> Enum.each(fn record ->
      Memento.Query.delete_record(record)
      %{record | id: {record.owner_key, new_key}, target_key: new_key, target: new_name} |> Memento.Query.write()
    end)
  end

  defp rewrite_history_message(%Message{params: [target | rest]} = message, old_key, new_name) do
    if channel_name?(target) and CaseMapping.normalize(target) == old_key,
      do: %{message | params: [new_name | rest]},
      else: message
  end

  defp rewrite_history_message(%{kind: :multiline, target: target, lines: lines} = message, old_key, new_name) do
    if channel_name?(target) and CaseMapping.normalize(target) == old_key do
      %{
        message
        | target: new_name,
          lines: Enum.map(lines, &rewrite_history_message(&1, old_key, new_name))
      }
    else
      message
    end
  end

  defp rewrite_history_message(message, _old_key, _new_name), do: message

  defp relay_rename(actor, users, old_name, new_name, reason) do
    {modern, legacy} = Enum.split_with(users, &("draft/channel-rename" in &1.capabilities))
    rename = %Message{command: "RENAME", params: [old_name, new_name], trailing: reason}
    Dispatcher.broadcast(rename, actor, modern)

    Dispatcher.broadcast(
      %Message{command: "PART", params: [old_name], trailing: reason || "Channel renamed"},
      actor,
      legacy
    )

    Dispatcher.broadcast(%Message{command: "JOIN", params: [new_name]}, actor, legacy)
  end

  defp fail(user, code, context, description) do
    %StandardReply{type: :fail, command: "RENAME", code: code, context: [context], description: description}
    |> Dispatcher.broadcast(:server, user)
  end
end
