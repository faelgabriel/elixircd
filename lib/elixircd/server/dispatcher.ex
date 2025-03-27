defmodule ElixIRCd.Server.Dispatcher do
  @moduledoc """
  Module for dispatching messages to users.
  """

  require Logger

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @doc """
  Broadcasts messages to the given users.
  """
  @spec broadcast(
          Message.t() | [Message.t()],
          User.t() | UserChannel.t() | [User.t() | UserChannel.t()]
        ) :: :ok
  def broadcast(messages, users) when is_list(messages) and is_list(users) do
    messages |> Enum.each(&broadcast(&1, users))
    :ok
  end

  def broadcast(message, users) when not is_list(message) and is_list(users) do
    raw_message = Message.unparse!(message)
    users |> Enum.each(&send_packet(&1, raw_message))
  end

  def broadcast(messages, user) when is_list(messages) and not is_list(user) do
    messages |> Enum.each(&broadcast(&1, user))
  end

  def broadcast(message, user) when not is_list(message) and not is_list(user) do
    raw_message = Message.unparse!(message)
    send_packet(user, raw_message)
  end

  @spec send_packet(User.t() | UserChannel.t(), String.t()) :: :ok
  defp send_packet(%UserChannel{user_pid: pid}, raw_message), do: Connection.handle_send(pid, raw_message <> "\r\n")
  defp send_packet(%User{pid: pid}, raw_message), do: Connection.handle_send(pid, raw_message <> "\r\n")
end
