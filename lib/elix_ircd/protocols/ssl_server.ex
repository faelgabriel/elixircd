defmodule ElixIRCd.Protocols.SslServer do
  @moduledoc """
  Module for the SSL server protocol.
  """

  alias ElixIRCd.Handlers.ServerHandler

  require Logger

  @behaviour :ranch_protocol
  @timeout 300_000

  @doc """
  Starts a linked process for the SSL server protocol.

  This function initializes the SSL server process and links it to the calling process.

  ## Parameters
  - `ref`: The reference to the Ranch listener.
  - `transport`: The transport module (e.g., :ranch_ssl).
  - `opts`: Options for the server.

  ## Returns
  - `{:ok, pid}` on successful start of the process.
  """
  @spec start_link(ref :: any(), transport :: atom(), opts :: keyword()) :: {:ok, pid()}
  def start_link(ref, transport, opts) do
    {:ok, spawn_link(__MODULE__, :init, [ref, transport, opts])}
  end

  @doc """
  Initializes the SSL server after a connection is established.

  This function is called after a successful connection is established to initialize the server.

  ## Parameters
  - `ref`: The reference to the Ranch listener.
  - `transport`: The transport module.
  - `_opts`: Options for the server (currently ignored).

  ## Returns
  - `:ok` if the connection is successfully handled.
  - `:error` in case of an error.
  """
  @spec init(ref :: any(), transport :: atom(), _opts :: keyword()) :: :ok | :error
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

  # Continuously processes incoming data on the SSL server.
  # This function is the main loop of the server, handling incoming data and managing the socket's state.
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

        # Future:: Handle manual closed connection - maybe with Registry?
    after
      @timeout ->
        ServerHandler.handle_quit_socket(socket, "Connection Timeout")
        :ok
    end
  end
end
