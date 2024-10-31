defmodule ElixIRCd.Server.WsPlug do
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
  """
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    subprotocol =
      get_req_header(conn, "sec-websocket-protocol")
      |> List.first()
      |> maybe_select_protocol()

    timeout = Application.get_env(:elixircd, :user)[:timeout]
    transport = if conn.scheme == :http, do: :ws, else: :wss

    conn
    |> maybe_response_protocol(subprotocol)
    # Feature: text and binary data should be handled accordingly to the subprotocol negotiation
    |> WebSockAdapter.upgrade(ElixIRCd.WsServer, %{conn: conn, subprotocol: subprotocol, transport: transport},
      timeout: timeout
    )
    |> halt()
  end

  @spec maybe_select_protocol(nil | String.t()) :: String.t() | nil
  defp maybe_select_protocol(nil), do: nil

  defp maybe_select_protocol(protocols) do
    protocols
    |> String.split(", ")
    |> Enum.find(&(&1 in ["text.ircv3.net", "binary.ircv3.net"]))
  end

  @spec maybe_response_protocol(Plug.Conn.t(), nil | String.t()) :: Plug.Conn.t()
  defp maybe_response_protocol(conn, nil), do: conn
  defp maybe_response_protocol(conn, protocol), do: put_resp_header(conn, "sec-websocket-protocol", protocol)
end
