defmodule ElixIRCd.Server.HttpPlug do
  @moduledoc """
  Plug for handling WebSocket upgrades and IRCv3 subprotocol negotiation.

  See more at https://ircv3.net/specs/extensions/websocket#websocket-features-and-encoding
  """

  import Plug.Conn

  @doc """
  Initializes the plug options.
  """
  @spec init(keyword()) :: keyword()
  def init(options), do: options

  @doc """
  Handles the WebSocket connection request, negotiates the subprotocol, and upgrades the connection.
  If a supported IRC subprotocol is found in the request header, it responds with the chosen protocol.
  Returns 404 if the connection is not a WebSocket upgrade request.
  """
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if websocket_request?(conn) do
      handle_websocket_request(conn)
    else
      handle_http_request(conn)
    end
  end

  @spec handle_websocket_request(Plug.Conn.t()) :: Plug.Conn.t()
  defp handle_websocket_request(conn) do
    subprotocol =
      get_req_header(conn, "sec-websocket-protocol")
      |> List.first()
      |> maybe_select_protocol()

    timeout = Application.get_env(:elixircd, :user)[:timeout]
    transport = if conn.scheme == :http, do: :ws, else: :wss

    conn
    |> maybe_response_protocol(subprotocol)
    # Feature: text and binary data should be handled accordingly to the subprotocol negotiation
    |> WebSockAdapter.upgrade(ElixIRCd.Server.WsListener, %{conn: conn, subprotocol: subprotocol, transport: transport},
      timeout: timeout
    )
    |> halt()
  end

  @spec handle_http_request(Plug.Conn.t()) :: Plug.Conn.t()
  defp handle_http_request(conn) do
    send_resp(conn, 404, "Not Found")
  end

  @spec websocket_request?(Plug.Conn.t()) :: boolean()
  defp websocket_request?(conn) do
    conn
    |> get_req_header("upgrade")
    |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end

  @spec maybe_select_protocol(nil | String.t()) :: String.t() | nil
  defp maybe_select_protocol(nil), do: nil

  defp maybe_select_protocol(protocols) do
    protocols
    |> String.split(~r/,\s*/)
    # Future: Use the subprotocol to determine the type of data to send
    |> Enum.find(&(&1 in ["text.ircv3.net", "binary.ircv3.net"]))
  end

  @spec maybe_response_protocol(Plug.Conn.t(), nil | String.t()) :: Plug.Conn.t()
  defp maybe_response_protocol(conn, nil), do: conn
  defp maybe_response_protocol(conn, protocol), do: put_resp_header(conn, "sec-websocket-protocol", protocol)
end
