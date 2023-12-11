defmodule ElixIRCd.Protocols.TcpServer do
  @moduledoc """
  Module for the TCP server protocol.
  """

  alias ElixIRCd.Core.Server

  require Logger

  @behaviour :ranch_protocol
  @timeout 120_000
  @reuseaddr Mix.env() in [:dev, :test]

  @doc """
  Starts a linked user connection process for the TCP server protocol.

  This function initializes the TCP server process and links it to the calling process.

  ## Parameters
  - `ref`: The reference to the Ranch listener.
  - `transport`: The transport module (e.g., :ranch_tcp).
  - `opts`: Options for the server.

  ## Returns
  - `{:ok, pid}` on successful start of the process.
  """
  @spec start_link(ref :: pid(), transport :: module(), opts :: keyword()) :: {:ok, pid()}
  def start_link(ref, transport, opts) do
    {:ok, spawn_link(__MODULE__, :init, [ref, transport, opts])}
  end

  @doc """
  Initializes the TCP server after a connection is established.

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
        Logger.error("TCP Handshake Error: #{inspect(reason)}")
        :error

      {:error, reason} ->
        Logger.error("Server Error: #{inspect(reason)}")
        :error
    end
  end

  # Continuously processes incoming data on the TCP server.
  # This function is the main loop of the server, handling incoming data and managing the socket's state.
  @spec loop(port(), atom()) :: :ok
  defp loop(socket, transport) do
    transport.setopts(socket, active: :once)

    receive do
      {:tcp, ^socket, data} ->
        Server.handle_packet(socket, data)
        loop(socket, transport)

      {:tcp_closed, ^socket} ->
        Server.handle_disconnect(socket, transport, "Connection Closed")

      {:tcp_error, ^socket, reason} ->
        Server.handle_disconnect(socket, transport, "Connection Error: #{reason}")

      {:quit, ^socket, reason} ->
        Server.handle_disconnect(socket, transport, reason)
    after
      @timeout ->
        Server.handle_disconnect(socket, transport, "Connection Timeout")
    end
  end
end
