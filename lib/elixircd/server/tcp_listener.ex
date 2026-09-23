defmodule ElixIRCd.Server.TcpListener do
  @moduledoc """
  Module for handling IRC connections over TCP and TLS.
  """

  use ThousandIsland.Handler

  require Logger

  alias ElixIRCd.Server.Connection

  @type state :: %{
          transport: :tcp | :tls,
          quit_reason?: String.t() | nil
        }

  @impl ThousandIsland.Handler
  def handle_connection(socket, _state) do
    pid = self()
    timeout = Application.fetch_env!(:elixircd, :user)[:inactivity_timeout_ms]

    transport =
      case socket do
        %{transport_module: ThousandIsland.Transports.TCP} -> :tcp
        %{transport_module: ThousandIsland.Transports.SSL} -> :tls
      end

    Logger.debug("New connection: #{inspect(pid)} (#{transport})")

    state = %{transport: transport}

    with {:ok, {remote_ip, remote_port}} <- ThousandIsland.Socket.peername(socket),
         {:ok, {_local_ip, port}} <- ThousandIsland.Socket.sockname(socket),
         :ok <-
           Connection.handle_connect(pid, transport, %{
             ip_address: remote_ip,
             port_connected: port,
             client_port: remote_port
           }),
         :ok <- ThousandIsland.Socket.setopts(socket, packet: :line, packet_size: Connection.max_wire_length()) do
      {:continue, state, {:persistent, timeout}}
    else
      :close -> {:close, state}
      {:error, _reason} -> {:close, state}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(_data, _socket, %{quit_reason: _reason} = state), do: {:continue, state}

  def handle_data(data, _socket, state) do
    case Connection.handle_receive(self(), data) do
      :ok ->
        {:continue, state}

      {:quit, reason} ->
        # Command replies are already queued in this process's mailbox.
        send(self(), {:disconnect, reason})
        {:continue, Map.put(state, :quit_reason, reason)}
    end
  end

  @impl GenServer
  def handle_info({:broadcast, message}, {socket, state}) when is_binary(message) do
    ThousandIsland.Socket.send(socket, message)
    {:noreply, {socket, state}}
  end

  def handle_info({:disconnect, reason}, {socket, state}) do
    {:stop, {:shutdown, :local_closed}, {socket, Map.put(state, :quit_reason, reason)}}
  end

  def handle_info({:EXIT, _pid, _type}, {socket, state}), do: {:noreply, {socket, state}}

  @impl ThousandIsland.Handler
  # TLS can fail before handle_connection/2 initializes the IRC session state.
  def handle_error(_reason, _socket, []), do: :ok

  def handle_error(_reason, _socket, state) do
    Connection.handle_disconnect(self(), state.transport, "Connection Error")
  end

  @impl ThousandIsland.Handler
  def handle_timeout(_socket, []), do: :ok

  def handle_timeout(_socket, state) do
    Connection.handle_disconnect(self(), state.transport, "Connection Timeout")
  end

  @impl ThousandIsland.Handler
  def handle_shutdown(_socket, []), do: :ok

  def handle_shutdown(_socket, state) do
    Connection.handle_disconnect(self(), state.transport, "Server Shutdown")
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, []), do: :ok

  def handle_close(_socket, state) do
    Connection.handle_disconnect(self(), state.transport, state[:quit_reason] || "Connection Closed")
  end
end
