defmodule ElixIRCd.Server.Dispatcher do
  @moduledoc """
  Module for dispatching messages to users.
  """

  require Logger

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.MessageTags
  alias ElixIRCd.Utils.Protocol

  @type target :: pid() | User.t() | UserChannel.t()
  @type context :: :server | :chanserv | :nickserv | User.t() | nil

  @doc """
  Broadcasts messages with context to the given targets.

  The context can be:
  - A User struct: Automatically resolves the user prefix and message tags
  - :server: Automatically resolves the server prefix
  - :chanserv: Automatically resolves the ChanServ service prefix
  - :nickserv: Automatically resolves the NickServ service prefix
  - nil: Does not resolve any prefix or tags
  """
  @spec broadcast(Message.t() | [Message.t()], context(), target() | [target()]) :: :ok
  def broadcast([], _context, _targets), do: :ok

  def broadcast(messages, %User{} = user, targets) when is_list(messages) do
    Enum.map(messages, &add_user_context(&1, user))
    |> do_broadcast(targets)
  end

  def broadcast(message, %User{} = user, targets) do
    add_user_context(message, user)
    |> do_broadcast(targets)
  end

  def broadcast(messages, :server, targets) when is_list(messages) do
    Enum.map(messages, &add_server_prefix/1)
    |> do_broadcast(targets)
  end

  def broadcast(message, :server, targets) do
    add_server_prefix(message)
    |> do_broadcast(targets)
  end

  def broadcast(messages, :chanserv, targets) when is_list(messages) do
    Enum.map(messages, &add_chanserv_prefix/1)
    |> do_broadcast(targets)
  end

  def broadcast(message, :chanserv, targets) do
    add_chanserv_prefix(message)
    |> do_broadcast(targets)
  end

  def broadcast(messages, :nickserv, targets) when is_list(messages) do
    Enum.map(messages, &add_nickserv_prefix/1)
    |> do_broadcast(targets)
  end

  def broadcast(message, :nickserv, targets) do
    add_nickserv_prefix(message)
    |> do_broadcast(targets)
  end

  def broadcast(messages, nil, targets) do
    do_broadcast(messages, targets)
  end

  @spec do_broadcast(Message.t() | [Message.t()], target() | [target()]) :: :ok
  defp do_broadcast(_messages, []), do: :ok

  defp do_broadcast(messages, targets) when is_list(messages) and is_list(targets) do
    Enum.each(messages, &do_broadcast(&1, targets))
  end

  defp do_broadcast(message, targets) when is_list(targets) do
    user_channel_pids = for %UserChannel{user_pid: pid} <- targets, do: pid
    users_map = fetch_users_map(user_channel_pids)

    Enum.each(targets, fn
      %UserChannel{user_pid: pid} -> do_broadcast(message, Map.get(users_map, pid, pid))
      target -> do_broadcast(message, target)
    end)
  end

  defp do_broadcast(messages, target) when is_list(messages) do
    Enum.each(messages, &do_broadcast(&1, target))
  end

  defp do_broadcast(message, %User{} = user) do
    message
    |> filter_tags(user)
    |> Message.unparse!()
    |> then(&Connection.handle_send(user.pid, &1))
  end

  defp do_broadcast(message, %UserChannel{user_pid: pid}) do
    message
    |> Message.unparse!()
    |> then(&Connection.handle_send(pid, &1))
  end

  defp do_broadcast(message, pid) when is_pid(pid) do
    message
    |> Message.unparse!()
    |> then(&Connection.handle_send(pid, &1))
  end

  @spec fetch_users_map([pid()]) :: %{pid() => User.t()}
  defp fetch_users_map([]), do: %{}

  defp fetch_users_map(user_channel_pids) do
    Memento.transaction!(fn ->
      Users.get_by_pids(user_channel_pids)
      |> Map.new(fn user -> {user.pid, user} end)
    end)
  end

  @spec add_user_context(Message.t(), User.t()) :: Message.t()
  defp add_user_context(message, user) do
    message
    |> add_prefix(Protocol.user_mask(user))
    |> MessageTags.maybe_add_bot_tag(user)
  end

  @spec add_server_prefix(Message.t()) :: Message.t()
  defp add_server_prefix(message) do
    add_prefix(message, Application.get_env(:elixircd, :server)[:hostname])
  end

  @spec add_chanserv_prefix(Message.t()) :: Message.t()
  defp add_chanserv_prefix(message) do
    hostname = Application.get_env(:elixircd, :server)[:hostname]
    add_prefix(message, "ChanServ!service@#{hostname}")
  end

  @spec add_nickserv_prefix(Message.t()) :: Message.t()
  defp add_nickserv_prefix(message) do
    hostname = Application.get_env(:elixircd, :server)[:hostname]
    add_prefix(message, "NickServ!service@#{hostname}")
  end

  @spec add_prefix(Message.t(), String.t()) :: Message.t()
  defp add_prefix(%Message{prefix: nil} = message, prefix) do
    %{message | prefix: prefix}
  end

  defp add_prefix(message, _prefix), do: message

  @spec filter_tags(Message.t(), User.t()) :: Message.t()
  defp filter_tags(%Message{tags: tags} = message, user) when map_size(tags) > 0 do
    MessageTags.filter_tags_for_recipient(message, user)
  end

  defp filter_tags(message, _user), do: message
end
