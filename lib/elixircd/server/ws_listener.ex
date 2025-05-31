defmodule ElixIRCd.Server.WsListener do
  @moduledoc """
  Module for handling IRC connections over WS and WSS.
  """

  @behaviour WebSock

  require Logger

  alias ElixIRCd.Server.Connection

  @type state :: %{
          conn: Plug.Conn.t(),
          subprotocol: nil | String.t(),
          transport: :ws | :wss,
          quit_reason: String.t() | nil
        }

  @impl WebSock
  def init(%{conn: conn, transport: transport} = state) do
    pid = self()

    Logger.debug("New connection: #{inspect(pid)} (#{inspect(transport)})")

    connection_data = %{
      ip_address: conn.remote_ip,
      port_connected: conn.port
    }

    case Connection.handle_connect(pid, transport, connection_data) do
      :ok -> {:ok, state}
      :close -> {:stop, :normal, state}
    end
  end

  @impl WebSock
  def handle_in({data, [opcode: _opcode]}, state) do
    Connection.handle_recv(self(), data)
    |> case do
      :ok -> {:ok, state}
      {:quit, reason} -> {:stop, :normal, {1000, reason}, Map.put(state, :quit_reason, reason)}
    end
  end

  @impl WebSock
  def handle_info({:broadcast, message}, state) when is_binary(message) do
    {:push, {:text, message}, state}
  end

  def handle_info({:disconnect, reason}, state) do
    {:stop, :normal, {1000, reason}, Map.put(state, :quit_reason, reason)}
  end

  def handle_info({:EXIT, _pid, _type}, state), do: {:ok, state}

  @impl WebSock
  def terminate(reason, %{transport: transport} = state) do
    disconnect_reason =
      case reason do
        {:error, _reason} -> "Connection Error"
        :timeout -> "Connection Timeout"
        :shutdown -> "Server Shutdown"
        reason when reason in [:normal, :remote] -> state[:quit_reason] || "Connection Closed"
      end

    Connection.handle_disconnect(self(), transport, disconnect_reason)
  end
end
