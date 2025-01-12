defmodule ElixIRCd.Server.Messaging do
  @moduledoc """
  Module for the server messaging.
  """

  require Logger

  alias ElixIRCd.Message
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.WsServer

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
  # Ranch
  defp send_packet(%UserChannel{user_socket: socket, user_transport: transport}, raw_message)
       when transport in [:ranch_tcp, :ranch_ssl] do
    transport_send(socket, transport, raw_message)
  end

  defp send_packet(%User{socket: socket, transport: transport}, raw_message)
       when transport in [:ranch_tcp, :ranch_ssl] do
    transport_send(socket, transport, raw_message)
  end

  # Bandit
  defp send_packet(%UserChannel{user_pid: pid}, raw_message) do
    process_send(pid, raw_message)
  end

  defp send_packet(%User{pid: pid}, raw_message) do
    process_send(pid, raw_message)
  end

  @spec transport_send(:inet.socket(), :ranch_tcp | :ranch_ssl, String.t()) :: :ok
  # With Ranch, we send the message directly to the socket.
  defp transport_send(socket, transport, raw_message) do
    Logger.debug("-> #{inspect(raw_message)}")
    transport.send(socket, raw_message <> "\r\n")
  end

  @spec process_send(pid(), String.t()) :: :ok
  # With Bandit, we send the message to the connection process.
  defp process_send(pid, raw_message) do
    Logger.debug("-> #{inspect(raw_message)}")
    WsServer.send_message(pid, raw_message)
  end
end
