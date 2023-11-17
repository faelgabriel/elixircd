defmodule ElixIRCd.Protocols.TcpServer do
  @moduledoc """
  Module for the TCP server protocol.
  """

  alias ElixIRCd.Handlers.ServerHandler

  require Logger

  @behaviour :ranch_protocol
  @timeout 300_000

  def start_link(ref, transport, opts) do
    {:ok, spawn_link(__MODULE__, :init, [ref, transport, opts])}
  end

  def init(ref, transport, _opts) do
    case :ranch.handshake(ref) do
      {:ok, socket} ->
        ServerHandler.handle_connect_socket(socket, transport)

        transport.setopts(socket, active: :once)
        loop(socket, transport)

      {:continue, reason} ->
        Logger.error("TCP Handshake Error: #{inspect(reason)}")
        :error
    end
  end

  defp loop(socket, transport, buffer \\ "") do
    receive do
      {:tcp, ^socket, data} ->
        remainder_buffer = ServerHandler.handle_stream(socket, buffer, data)

        transport.setopts(socket, active: :once)
        loop(socket, transport, remainder_buffer)

      {:tcp_closed, ^socket} ->
        ServerHandler.handle_quit_socket(socket, "Connection Closed")
        :ok

      {:tcp_error, ^socket, reason} ->
        ServerHandler.handle_quit_socket(socket, "Connection Error: " <> reason)
        :ok

      # TODO: Handle manual closed connection - maybe with Registry?
    after
      @timeout ->
        ServerHandler.handle_quit_socket(socket, "Connection Timeout")
        :ok
    end
  end
end
