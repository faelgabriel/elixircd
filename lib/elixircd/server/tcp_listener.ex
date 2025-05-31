defmodule ElixIRCd.Server.TcpListener do
  @moduledoc """
  Module for handling IRC connections over TCP and TLS.
  """

  use ThousandIsland.Handler

  require Logger

  alias ElixIRCd.Server.Connection

  @type state :: %{
          transport: :tcp | :tls,
          quit_reason: String.t() | nil
        }

  @impl ThousandIsland.Handler
  def handle_connection(socket, _state) do
    pid = self()
    timeout = Application.get_env(:elixircd, :user)[:inactivity_timeout_ms]

    transport =
      case socket do
        %{transport_module: ThousandIsland.Transports.TCP} -> :tcp
        %{transport_module: ThousandIsland.Transports.SSL} -> :tls
      end

    Logger.debug("New connection: #{inspect(pid)} (#{transport})")

    {:ok, {remote_ip, port}} = ThousandIsland.Socket.sockname(socket)

    connection_data = %{
      ip_address: remote_ip,
      port_connected: port
    }

    state = %{transport: transport}

    case Connection.handle_connect(pid, transport, connection_data) do
      :ok ->
        ThousandIsland.Socket.setopts(socket, [{:packet, :line}])
        {:continue, state, {:persistent, timeout}}

      :close ->
        {:close, state}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, _socket, state) do
    case Connection.handle_receive(self(), data) do
      :ok -> {:continue, state}
      {:quit, reason} -> {:close, Map.put(state, :quit_reason, reason)}
    end
  end

  @impl GenServer
  def handle_info({:broadcast, message}, {socket, state}) when is_binary(message) do
    ThousandIsland.Socket.send(socket, message)
    {:noreply, {socket, state}, socket.read_timeout}
  end

  def handle_info({:disconnect, reason}, {socket, state}) do
    {:close, {socket, Map.put(state, :quit_reason, reason)}}
  end

  def handle_info({:EXIT, _pid, _type}, {socket, state}), do: {:noreply, {socket, state}, socket.read_timeout}

  @impl ThousandIsland.Handler
  def handle_error(_reason, _socket, state) do
    Connection.handle_disconnect(self(), state.transport, "Connection Error")
  end

  @impl ThousandIsland.Handler
  def handle_timeout(_socket, state) do
    Connection.handle_disconnect(self(), state.transport, "Connection Timeout")
  end

  @impl ThousandIsland.Handler
  def handle_shutdown(_socket, state) do
    Connection.handle_disconnect(self(), state.transport, "Server Shutdown")
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state) do
    Connection.handle_disconnect(self(), state.transport, state.quit_reason || "Connection Closed")
  end
end
