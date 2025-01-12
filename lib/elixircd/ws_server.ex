defmodule ElixIRCd.WsServer do
  @moduledoc """
  Module for handling IRC connections over WS and WSS.
  """

  @behaviour WebSock

  require Logger

  import ElixIRCd.Helper, only: [format_transport: 1]

  alias ElixIRCd.Server.Connection

  @type state :: %{conn: Plug.Conn.t(), subprotocol: nil | String.t(), transport: :ws | :wss}

  @doc """
  Initializes the connection to the server.

  This function is called after a successful connection is established.
  """
  @spec init(WebSock.state()) :: {:ok, state()}
  def init(%{conn: conn, transport: transport} = state) do
    pid = self()

    Logger.debug("New connection: #{inspect(pid)} (#{inspect(transport)})")

    connection_data = %{
      ip_address: conn.remote_ip,
      port_connected: conn.port
    }

    Connection.handle_connect(pid, transport, connection_data)

    {:ok, state}
  end

  @doc """
  Handles the incoming data packets.
  """
  @spec handle_in({binary(), opcode: WebSock.data_opcode()}, state()) ::
          {:ok, state()} | {:stop, {:disconnect, String.t()}, state()}
  def handle_in({data, [opcode: _opcode]}, state) do
    pid = self()

    Connection.handle_packet(pid, data)
    |> handle_packet_result(state)
  rescue
    exception ->
      stacktrace = __STACKTRACE__ |> Exception.format_stacktrace()
      Logger.critical("Error handling connection: #{inspect(exception)}\nStacktrace:\n#{stacktrace}")
      {:stop, {:disconnect, "Server Error"}, state}
  end

  @doc """
  Handles the incoming messages to the process.
  """
  @spec handle_info(tuple(), state()) :: {:push, WebSock.messages(), state()} | {:ok, state()}
  def handle_info({:broadcast, message}, state) when is_binary(message) do
    {:push, {:text, message}, state}
  end

  def handle_info({:EXIT, _pid, _type}, state) do
    {:ok, state}
  end

  @doc """
  Handles the connection termination.
  """
  @spec terminate(WebSock.close_reason(), state()) :: :ok
  def terminate(:timeout, %{transport: transport}) do
    Connection.handle_disconnect(self(), transport, "Connection Timeout")
  end

  def terminate({:error, {:disconnect, reason}}, %{transport: transport}) do
    Connection.handle_disconnect(self(), transport, reason)
  end

  def terminate({:error, reason}, %{transport: transport}) do
    Logger.warning("Connection error [#{format_transport(transport)}]: #{inspect(reason)}")
    Connection.handle_disconnect(self(), transport, "Connection Error")
  end

  def terminate(reason, %{transport: transport}) when reason in [:normal, :remote, :shutdown] do
    Connection.handle_disconnect(self(), transport, "Connection Closed")
  end

  @doc """
  Sends a message to the user connected at the PID.
  """
  @spec send_message(pid(), String.t()) :: :ok
  def send_message(pid, message) do
    send(pid, {:broadcast, message})
    :ok
  end

  @spec handle_packet_result(:ok | {:quit, String.t()}, state()) ::
          {:ok, state()} | {:stop, {:disconnect, String.t()}, state()}
  defp handle_packet_result(:ok, state), do: {:ok, state}
  defp handle_packet_result({:quit, reason}, state), do: {:stop, {:disconnect, reason}, state}
end
