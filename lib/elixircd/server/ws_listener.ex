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
          quit_reason?: String.t() | nil
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
  def handle_in(_frame, %{quit_reason: _reason} = state), do: {:ok, state}

  def handle_in({data, [opcode: opcode]}, state) do
    processed_data = process_incoming_data(data, opcode)

    Connection.handle_receive(self(), processed_data)
    |> case do
      :ok ->
        {:ok, state}

      {:quit, reason} ->
        # Send queued command replies before the WebSocket close frame.
        send(self(), {:disconnect, reason})
        {:ok, Map.put(state, :quit_reason, reason)}
    end
  end

  @impl WebSock
  def handle_info({:broadcast, message}, %{subprotocol: subprotocol} = state) when is_binary(message) do
    frame = create_outgoing_frame(message, subprotocol)
    {:push, frame, state}
  end

  def handle_info({:disconnect, uid, reason}, state) when is_binary(uid) do
    if Connection.current_uid() == uid do
      {:stop, :normal, {1000, reason}, Map.put(state, :quit_reason, reason)}
    else
      {:ok, state}
    end
  end

  def handle_info({:disconnect, reason}, state) do
    {:stop, :normal, {1000, reason}, Map.put(state, :quit_reason, reason)}
  end

  def handle_info({:s2s_reply, uid, result}, state) do
    Connection.handle_s2s_reply(self(), uid, result)
    {:ok, state}
  end

  def handle_info({:s2s_reply, uid, request_id, result, context}, state) do
    Connection.handle_s2s_reply(self(), uid, request_id, result, context)
    {:ok, state}
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

  @spec process_incoming_data(binary(), :text | :binary) :: binary()
  defp process_incoming_data(data, :text) do
    if Application.fetch_env!(:elixircd, :settings)[:utf8_only], do: data, else: ensure_utf8_valid(data)
  end

  defp process_incoming_data(data, :binary), do: data

  @spec create_outgoing_frame(binary(), nil | String.t()) :: {:text, binary()} | {:binary, binary()}
  defp create_outgoing_frame(message, subprotocol) do
    message = String.trim_trailing(message, "\r\n")

    case subprotocol do
      "text.ircv3.net" -> {:text, text_frame(message)}
      "binary.ircv3.net" -> {:binary, message}
      # No subprotocol or unknown subprotocol - default to text for compatibility with legacy clients
      _ -> {:text, text_frame(message)}
    end
  end

  @spec text_frame(binary()) :: String.t()
  defp text_frame(message) do
    message
    |> ensure_utf8_valid()
    |> fit_text_frame()
  end

  # IRCv3 message tags have their own budget; only the non-tag portion is
  # constrained to 510 bytes because WebSocket frames omit the trailing CRLF.
  @spec fit_text_frame(String.t()) :: String.t()
  defp fit_text_frame("@" <> rest = message) do
    case String.split(rest, " ", parts: 2) do
      [tags, data] -> "@" <> tags <> " " <> fit_non_tag_data(data)
      [_tag_only] -> fit_non_tag_data(message)
    end
  end

  defp fit_text_frame(message), do: fit_non_tag_data(message)

  @spec fit_non_tag_data(String.t()) :: String.t()
  defp fit_non_tag_data(data) when byte_size(data) <= 510, do: data
  defp fit_non_tag_data(data), do: data |> binary_part(0, 510) |> trim_partial_codepoint()

  @spec trim_partial_codepoint(binary()) :: String.t()
  defp trim_partial_codepoint(data) do
    if String.valid?(data), do: data, else: trim_partial_codepoint(binary_part(data, 0, byte_size(data) - 1))
  end

  @spec ensure_utf8_valid(binary()) :: binary()
  defp ensure_utf8_valid(data) do
    if String.valid?(data) do
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
