defmodule ElixIRCd.Server.HttpPlugTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Mimic

  import Plug.Conn
  import Plug.Test

  alias ElixIRCd.Server.HttpPlug

  describe "HTTP request handling" do
    test "returns 404 for regular HTTP requests" do
      conn =
        conn(:get, "/")
        |> HttpPlug.call([])

      assert conn.status == 404
      assert conn.resp_body == "Not Found"
    end
  end

  describe "WebSocket request handling" do
    test "upgrades WebSocket connections" do
      expect(WebSockAdapter, :upgrade, fn conn, handler, state, opts ->
        assert handler == ElixIRCd.Server.WsListener
        assert state.transport == :ws
        assert state.subprotocol == nil
        assert opts[:timeout] == 180_000

        conn
        |> Plug.Conn.assign(:upgraded, true)
        |> Plug.Conn.halt()
      end)

      conn =
        conn(:get, "/")
        |> put_req_header("upgrade", "websocket")
        |> HttpPlug.call([])

      assert conn.assigns.upgraded
      assert conn.halted
    end

    test "handles secure websocket connections" do
      expect(WebSockAdapter, :upgrade, fn conn, _handler, state, _opts ->
        assert state.transport == :wss

        conn
        |> Plug.Conn.assign(:upgraded, true)
        |> Plug.Conn.halt()
      end)

      conn =
        conn(:get, "/")
        |> put_req_header("upgrade", "websocket")
        |> Map.put(:scheme, :https)
        |> HttpPlug.call([])

      assert conn.assigns.upgraded
    end

    test "negotiates IRC subprotocols correctly" do
      expect(WebSockAdapter, :upgrade, fn conn, _handler, state, _opts ->
        assert state.subprotocol == "text.ircv3.net"

        conn
        |> Plug.Conn.assign(:upgraded, true)
        |> Plug.Conn.halt()
      end)

      conn =
        conn(:get, "/")
        |> put_req_header("upgrade", "websocket")
        |> put_req_header("sec-websocket-protocol", "text.ircv3.net, other.protocol")
        |> HttpPlug.call([])

      assert conn.assigns.upgraded
      assert Plug.Conn.get_resp_header(conn, "sec-websocket-protocol") == ["text.ircv3.net"]
    end

    test "supports binary.ircv3.net subprotocol" do
      expect(WebSockAdapter, :upgrade, fn conn, _handler, state, _opts ->
        assert state.subprotocol == "binary.ircv3.net"

        conn
        |> Plug.Conn.assign(:upgraded, true)
        |> Plug.Conn.halt()
      end)

      conn =
        conn(:get, "/")
        |> put_req_header("upgrade", "websocket")
        |> put_req_header("sec-websocket-protocol", "binary.ircv3.net")
        |> HttpPlug.call([])

      assert conn.assigns.upgraded
      assert Plug.Conn.get_resp_header(conn, "sec-websocket-protocol") == ["binary.ircv3.net"]
    end

    test "ignores unsupported subprotocols" do
      expect(WebSockAdapter, :upgrade, fn conn, _handler, state, _opts ->
        assert state.subprotocol == nil

        conn
        |> Plug.Conn.assign(:upgraded, true)
        |> Plug.Conn.halt()
      end)

      conn =
        conn(:get, "/")
        |> put_req_header("upgrade", "websocket")
        |> put_req_header("sec-websocket-protocol", "unsupported.protocol")
        |> HttpPlug.call([])

      assert conn.assigns.upgraded
      assert Plug.Conn.get_resp_header(conn, "sec-websocket-protocol") == []
    end
  end
end
