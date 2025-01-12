defmodule ElixIRCd.Server.BanditPlug do
  @moduledoc """
  A plug to handle WebSocket upgrades for the ElixIRCd server using the `WebSockAdapter`.

  It negotiates the IRC WebSocket subprotocol and performs the upgrade.
  See more at https://ircv3.net/specs/extensions/websocket#websocket-features-and-encoding
  """

  import Plug.Conn

  @doc """
  Initializes the plug options.
  """
  @spec init(keyword()) :: keyword()
  def init(options), do: options

  @doc """
  Handles the WebSocket connection request and negotiates the subprotocol.

  If a supported subprotocol is found in the request header, it responds with the chosen protocol and upgrades the
  connection. If no protocol is found, it upgrades without a protocol.
  """
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    selected_protocol =
      get_req_header(conn, "sec-websocket-protocol")
      |> List.first()
      |> maybe_select_protocol()

    conn
    |> maybe_set_protocol(selected_protocol)
    |> WebSockAdapter.upgrade(ElixIRCd.WsServer, %{subprotocol: selected_protocol}, timeout: 60_000)
    |> halt()
  end

  @spec maybe_set_protocol(Plug.Conn.t(), String.t() | nil) :: Plug.Conn.t()
  defp maybe_set_protocol(conn, nil), do: conn
  defp maybe_set_protocol(conn, protocol), do: put_resp_header(conn, "sec-websocket-protocol", protocol)

  @spec maybe_select_protocol(nil | String.t()) :: String.t() | nil
  defp maybe_select_protocol(nil), do: nil

  defp maybe_select_protocol(protocols) do
    protocols
    |> String.split(", ")
    |> Enum.find(&(&1 in ["text.ircv3.net", "binary.ircv3.net"]))
  end
end
