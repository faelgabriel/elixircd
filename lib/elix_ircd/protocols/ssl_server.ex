defmodule ElixIRCd.Protocols.SslServer do
  @moduledoc """
  Module for the SSL server protocol.
  """

  alias ElixIRCd.Handlers.ServerHandler

  require Logger

  @behaviour :ranch_protocol
  @timeout 300_000

  def start_link(ref, transport, opts) do
    {:ok, spawn_link(__MODULE__, :init, [ref, transport, opts])}
  end

  def init(ref, transport, opts) do
    ssl_opts = Keyword.get(opts, :ssl_opts, [])

    case :ranch.handshake(ref, ssl_opts) do
      {:ok, socket} ->
        ServerHandler.handle_connect_socket(socket, transport)

        transport.setopts(socket, active: :once)
        loop(socket, transport)

      {:continue, reason} ->
        Logger.error("SSL Handshake Error: #{inspect(reason)}")
        :error
    end
  end

  defp loop(socket, transport, buffer \\ "") do
    receive do
      {:ssl, ^socket, data} ->
        remainder_buffer = ServerHandler.handle_stream(socket, buffer, data)

        transport.setopts(socket, active: :once)
        loop(socket, transport, remainder_buffer)

      {:ssl_closed, ^socket} ->
        ServerHandler.handle_quit_socket(socket, "Connection Closed")
        :ok

      {:ssl_error, ^socket, reason} ->
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
