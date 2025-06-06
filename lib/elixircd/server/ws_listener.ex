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
  def handle_in({data, [opcode: opcode]}, %{subprotocol: subprotocol} = state) do
    processed_data = process_incoming_data(data, opcode, subprotocol)

    Connection.handle_receive(self(), processed_data)
    |> case do
      :ok -> {:ok, state}
      {:quit, reason} -> {:stop, :normal, {1000, reason}, Map.put(state, :quit_reason, reason)}
    end
  end

  @impl WebSock
  def handle_info({:broadcast, message}, %{subprotocol: subprotocol} = state) when is_binary(message) do
    frame = create_outgoing_frame(message, subprotocol)
    {:push, frame, state}
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

  @spec process_incoming_data(binary(), :text | :binary, nil | String.t()) :: binary()
  defp process_incoming_data(data, opcode, subprotocol) do
    case {opcode, subprotocol} do
      {:text, "text.ircv3.net"} ->
        ensure_utf8_valid(data)

      {:binary, "binary.ircv3.net"} ->
        data

      # No subprotocol negotiated or mismatched frame type for negotiated subprotocol - use data as-is
      _ ->
        case opcode do
          :text -> ensure_utf8_valid(data)
          :binary -> data
        end
    end
  end

  @spec create_outgoing_frame(binary(), nil | String.t()) :: {:text, binary()} | {:binary, binary()}
  defp create_outgoing_frame(message, subprotocol) do
    case subprotocol do
      "text.ircv3.net" -> {:text, ensure_utf8_valid(message)}
      "binary.ircv3.net" -> {:binary, message}
      # No subprotocol or unknown subprotocol - default to text for compatibility with legacy clients
      _ -> {:text, ensure_utf8_valid(message)}
    end
  end

  @spec ensure_utf8_valid(binary()) :: binary()
  defp ensure_utf8_valid(data) do
    utf8_only_enabled? = Application.get_env(:elixircd, :settings)[:utf8_only] || false

    # It does not replace invalid UTF8 if utf8_only is not enabled,
    # since the invalid UTF8 content will be handled by the Connection module.
    if utf8_only_enabled? or String.valid?(data) do
      data
    else
      replace_invalid_utf8(data, <<>>)
    end
  end

  @spec replace_invalid_utf8(binary(), binary()) :: binary()
  defp replace_invalid_utf8(<<>>, acc), do: acc

  defp replace_invalid_utf8(<<byte, rest::binary>>, acc) do
    case <<byte>> do
      <<valid_char::utf8>> ->
        replace_invalid_utf8(rest, acc <> <<valid_char::utf8>>)

      _ ->
        {codepoint, remaining} = String.next_codepoint(<<byte, rest::binary>>)

        if String.valid?(codepoint) do
          replace_invalid_utf8(remaining, acc <> codepoint)
        else
          replace_invalid_utf8(rest, acc <> "�")
        end
    end
  end
end
