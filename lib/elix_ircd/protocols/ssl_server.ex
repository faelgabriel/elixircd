defmodule ElixIRCd.Protocols.SslServer do
  @moduledoc """
  Module for the SSL server protocol.
  """

  alias ElixIRCd.Core.Server

  require Logger

  @behaviour :ranch_protocol
  @timeout 180_000
  @reuseaddr Mix.env() in [:dev, :test]

  @doc """
  Starts a linked user connection process for the SSL server protocol.

  This function initializes the SSL server process and links it to the calling process.

  ## Parameters
  - `ref`: The reference to the Ranch listener.
  - `transport`: The transport module (e.g., :ranch_ssl).
  - `opts`: Options for the server.

  ## Returns
  - `{:ok, pid}` on successful start of the process.
  """
  @spec start_link(ref :: pid(), transport :: module(), opts :: keyword()) :: {:ok, pid()}
  def start_link(ref, transport, opts) do
    {:ok, spawn_link(__MODULE__, :init, [ref, transport, opts])}
  end

  @doc """
  Initializes the SSL server after a connection is established.

  This function is called after a successful connection is established to initialize the server.

  ## Parameters
  - `ref`: The reference to the Ranch listener.
  - `transport`: The transport module.
  - `_opts`: Options for the server (currently not in use).

  ## Returns
  - `:ok` if the connection is successfully handled.
  - `:error` in case of an error.
  """
  @spec init(ref :: pid(), transport :: atom(), _opts :: keyword()) :: :ok | :error
  def init(ref, transport, _opts) do
    with {:ok, socket} <- :ranch.handshake(ref),
         {:ok, _new_user} <- Server.handle_connect(socket, transport, self()) do
      transport.setopts(socket, [
        {:packet, :line},
        {:reuseaddr, @reuseaddr}
      ])

      loop(socket, transport)
    else
      {:continue, reason} ->
        Logger.error("SSL Handshake Error: #{inspect(reason)}")
        :error

      {:error, reason} ->
        Logger.error("Server Error: #{inspect(reason)}")
        :error
    end
  end

  # Continuously processes incoming data on the SSL server.
  # This function is the main loop of the server, handling incoming data and managing the socket's state.
  @spec loop(:inet.socket(), atom()) :: :ok
  defp loop(socket, transport) do
    transport.setopts(socket, active: :once)

    receive do
      {:ssl, ^socket, data} ->
        Server.handle_packet(socket, data)
        loop(socket, transport)

      {:ssl_closed, ^socket} ->
        Server.handle_disconnect(socket, transport, "Connection Closed")

      {:ssl_error, ^socket, reason} ->
        Server.handle_disconnect(socket, transport, "Connection Error: #{reason}")

      {:user_quit, ^socket, reason} ->
        Server.handle_disconnect(socket, transport, reason)
    after
      @timeout ->
        Server.handle_disconnect(socket, transport, "Connection Timeout")
    end
  end
end
