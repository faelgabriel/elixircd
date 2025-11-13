defmodule ElixIRCd.Server.Dispatcher do
  @moduledoc """
  Module for dispatching messages to users.
  """

  require Logger

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.MessageTags

  @type target :: pid() | User.t() | UserChannel.t()
  @type context :: :server | User.t()

  @doc """
  Broadcasts messages with context to the given targets.

  The context can be:
  - A User struct: Automatically adds user prefix and bot tag if applicable
  - :server: Automatically adds server prefix

  This is the preferred way to broadcast messages as it automatically handles
  prefix and tag management based on the message context.
  """
  @spec broadcast(Message.t() | [Message.t()], context(), target() | [target()]) :: :ok
  def broadcast(messages, %User{} = user, targets) when is_list(messages) do
    messages
    |> Enum.map(fn message ->
      message
      |> maybe_add_user_prefix(user)
      |> MessageTags.maybe_add_bot_tag(user)
    end)
    |> do_broadcast(targets)
  end

  def broadcast(message, %User{} = user, targets) when not is_list(message) do
    message
    |> maybe_add_user_prefix(user)
    |> MessageTags.maybe_add_bot_tag(user)
    |> do_broadcast(targets)
  end

  def broadcast(messages, :server, targets) when is_list(messages) do
    messages
    |> Enum.map(&maybe_add_server_prefix/1)
    |> do_broadcast(targets)
  end

  def broadcast(message, :server, targets) when not is_list(message) do
    message
    |> maybe_add_server_prefix()
    |> do_broadcast(targets)
  end

  # Internal broadcast function that sends messages without adding context.
  # This should not be called directly - use broadcast/3 instead.
  @spec do_broadcast(Message.t() | [Message.t()], target() | [target()]) :: :ok
  defp do_broadcast(messages, targets) when is_list(messages) and is_list(targets) do
    messages |> Enum.each(&do_broadcast(&1, targets))
    :ok
  end

  defp do_broadcast(message, targets) when not is_list(message) and is_list(targets) do
    # Convert UserChannels to Users in one batch query, keeping order
    user_channel_pids = for %UserChannel{user_pid: pid} <- targets, do: pid

    users_map =
      if user_channel_pids != [] do
        fetch_users = fn ->
          ElixIRCd.Repositories.Users.get_by_pids(user_channel_pids)
          |> Map.new(fn user -> {user.pid, user} end)
        end

        if Memento.Transaction.inside?() do
          fetch_users.()
        else
          Memento.transaction!(fetch_users)
        end
      else
        %{}
      end

    # Broadcast to each target, replacing UserChannels with Users
    Enum.each(targets, fn
      %UserChannel{user_pid: pid} -> do_broadcast(message, Map.get(users_map, pid, pid))
      target -> do_broadcast(message, target)
    end)
  end

  defp do_broadcast(messages, target) when is_list(messages) and not is_list(target) do
    messages |> Enum.each(&do_broadcast(&1, target))
  end

  defp do_broadcast(message, target) when not is_list(message) and not is_list(target) do
    filtered_message = filter_message_for_target(message, target)
    raw_message = Message.unparse!(filtered_message)
    send_packet(target, raw_message)
  end

  # Adds user prefix to message if not already present
  @spec maybe_add_user_prefix(Message.t(), User.t()) :: Message.t()
  defp maybe_add_user_prefix(%Message{prefix: nil} = message, user) do
    %{message | prefix: ElixIRCd.Utils.Protocol.user_mask(user)}
  end

  defp maybe_add_user_prefix(message, _user), do: message

  # Adds server prefix to message if not already present
  @spec maybe_add_server_prefix(Message.t()) :: Message.t()
  defp maybe_add_server_prefix(%Message{prefix: nil} = message) do
    %{message | prefix: Application.get_env(:elixircd, :server)[:hostname]}
  end

  defp maybe_add_server_prefix(message), do: message

  # Filters message tags based on recipient's capabilities
  @spec filter_message_for_target(Message.t(), target()) :: Message.t()
  defp filter_message_for_target(%Message{tags: tags} = message, %User{} = user) when map_size(tags) > 0 do
    MessageTags.filter_tags_for_recipient(message, user)
  end

  defp filter_message_for_target(message, _target), do: message

  @spec send_packet(target(), String.t()) :: :ok
  defp send_packet(pid, raw_message) when is_pid(pid), do: Connection.handle_send(pid, raw_message)
  defp send_packet(%User{pid: pid}, raw_message), do: Connection.handle_send(pid, raw_message)
  defp send_packet(%UserChannel{user_pid: pid}, raw_message), do: Connection.handle_send(pid, raw_message)
end
