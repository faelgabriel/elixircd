defmodule ElixIRCd.Server do
  @moduledoc """
  Module for handling IRC connections over TCP and SSL.
  """

  @behaviour :ranch_protocol

  require Logger

  import ElixIRCd.Helper, only: [format_transport: 1, get_socket_ip: 1, get_socket_port_connected: 1]

  alias ElixIRCd.Server.Connection

  @doc """
  Starts a linked user connection process for the server protocol.

  This function initializes the server process and links it to the calling process.
  """
  @spec start_link(ref :: pid(), transport :: module(), opts :: keyword()) :: {:ok, pid()}
  def start_link(ref, transport, opts) do
    {:ok, spawn_link(__MODULE__, :init, [ref, transport, opts])}
  end

  @doc """
  Initializes the connection to the server.

  This function is called after a successful connection is established.
  """
  @spec init(ref :: pid(), transport :: atom(), _opts :: keyword()) :: :ok | :error
  def init(ref, transport, _opts) do
    with {:ok, socket} <- :ranch.handshake(ref),
         {:ok, ip_address} <- get_socket_ip(socket),
         {:ok, port_connected} <- get_socket_port_connected(socket) do
      pid = self()

      Logger.debug("New connection: #{inspect(pid)} (#{inspect(transport)})")

      connection_data = %{
        socket: socket,
        ip_address: ip_address,
        port_connected: port_connected
      }

      Connection.handle_connect(pid, transport, connection_data)
      transport.setopts(socket, [{:packet, :line}])

      handle_listening(pid, socket, transport)
    else
      reason ->
        Logger.info("Connection via #{format_transport(transport)} failed: #{inspect(reason)}")
        :error
    end
  end

  @spec handle_listening(pid(), :inet.socket(), atom()) :: :ok
  defp handle_listening(pid, socket, transport) do
    transport.setopts(socket, active: :once)

    receive do
      {protocol, ^socket, data} when protocol in [:tcp, :ssl] ->
        Connection.handle_packet(pid, data) |> handle_packet_result(pid, socket, transport)

      {protocol_closed, ^socket} when protocol_closed in [:tcp_closed, :ssl_closed] ->
        handle_disconnect(pid, socket, transport, "Connection Closed")

      {protocol_error, ^socket, reason} when protocol_error in [:tcp_error, :ssl_error] ->
        Logger.warning("Connection error [#{protocol_error}]: #{inspect(reason)}")
        handle_disconnect(pid, socket, transport, "Connection Error")

      {:disconnect, ^socket, reason} ->
        handle_disconnect(pid, socket, transport, reason)
    after
      Application.get_env(:elixircd, :user)[:timeout] ->
        handle_disconnect(pid, socket, transport, "Connection Timeout")
    end
  rescue
    exception ->
      stacktrace = __STACKTRACE__ |> Exception.format_stacktrace()
      Logger.critical("Error handling connection: #{inspect(exception)}\nStacktrace:\n#{stacktrace}")
      handle_disconnect(pid, socket, transport, "Server Error")
  end

  @spec handle_packet_result(:ok | {:quit, String.t()}, pid(), :inet.socket(), atom()) :: :ok
  defp handle_packet_result(:ok, pid, socket, transport),
    do: handle_listening(pid, socket, transport)

  defp handle_packet_result({:quit, reason}, pid, socket, transport),
    do: handle_disconnect(pid, socket, transport, reason)

  @spec handle_disconnect(pid(), :inet.socket(), atom(), String.t()) :: :ok
  defp handle_disconnect(pid, socket, transport, reason) do
    transport.close(socket)
    Connection.handle_disconnect(pid, transport, reason)
  end
end
