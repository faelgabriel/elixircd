defmodule ElixIRCd.MessageCaseTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  alias ElixIRCd.Client
  alias ElixIRCd.WsServer
  alias ExUnit.AssertionError

  describe "assert_sent_messages_amount/2" do
    test "passes if the amount of messages sent is correct" do
      {:ok, tcp_socket} = Client.connect(:tcp)
      {:ok, ssl_socket} = Client.connect(:ssl)
      ws_pid = self()

      :ranch_tcp.send(tcp_socket, "PING :test")
      :ranch_tcp.send(tcp_socket, "PING :test")
      :ranch_ssl.send(ssl_socket, "PING :test")
      WsServer.send_message(ws_pid, "PING :test")

      assert_sent_messages_amount(tcp_socket, 2)
      assert_sent_messages_amount(ssl_socket, 1)
      assert_sent_messages_amount(ws_pid, 1)
    end

    test "raises an error if the amount of messages sent is incorrect" do
      {:ok, tcp_socket} = Client.connect(:tcp)
      {:ok, ssl_socket} = Client.connect(:ssl)

      :ranch_tcp.send(tcp_socket, "PING :test")
      :ranch_tcp.send(tcp_socket, "PING :test")
      :ranch_ssl.send(ssl_socket, "PING :test")

      assert_raise AssertionError, fn ->
        assert_sent_messages_amount(tcp_socket, 1)
      end

      assert_raise AssertionError, fn ->
        assert_sent_messages_amount(ssl_socket, 2)
      end
    end
  end

  describe "assert_sent_messages/1" do
    test "passes if messages are sent in the correct order" do
      {:ok, tcp_socket} = Client.connect(:tcp)
      {:ok, ssl_socket} = Client.connect(:ssl)

      :ranch_tcp.send(tcp_socket, "PING :test1")
      :ranch_tcp.send(tcp_socket, "PING :test2")
      :ranch_ssl.send(ssl_socket, "PING :test1")
      :ranch_ssl.send(ssl_socket, "PING :test2")

      assert_sent_messages([
        {tcp_socket, "PING :test1"},
        {tcp_socket, "PING :test2"},
        {ssl_socket, "PING :test1"},
        {ssl_socket, "PING :test2"}
      ])
    end

    test "passes if messages are not sent in the correct order and validate_order? is false" do
      {:ok, tcp_socket} = Client.connect(:tcp)
      {:ok, ssl_socket} = Client.connect(:ssl)

      :ranch_tcp.send(tcp_socket, "PING :test1")
      :ranch_tcp.send(tcp_socket, "PING :test2")
      :ranch_ssl.send(ssl_socket, "PING :test1")
      :ranch_ssl.send(ssl_socket, "PING :test2")

      assert_sent_messages(
        [
          {ssl_socket, "PING :test2"},
          {tcp_socket, "PING :test2"},
          {tcp_socket, "PING :test1"},
          {ssl_socket, "PING :test1"}
        ],
        validate_order?: false
      )
    end

    test "passes if the messages are sent and expected message is a regex" do
      {:ok, tcp_socket} = Client.connect(:tcp)
      {:ok, ssl_socket} = Client.connect(:ssl)

      :ranch_tcp.send(tcp_socket, "PING :test")
      :ranch_ssl.send(ssl_socket, "PING :test")

      assert_sent_messages([
        {tcp_socket, ~r/^PING/},
        {ssl_socket, ~r/^PING/}
      ])
    end

    test "raises an error if messages are not sent in the correct order" do
      {:ok, tcp_socket} = Client.connect(:tcp)
      {:ok, ssl_socket} = Client.connect(:ssl)

      :ranch_tcp.send(tcp_socket, "PING :test1")
      :ranch_tcp.send(tcp_socket, "PING :test2")
      :ranch_ssl.send(ssl_socket, "PING :test1")
      :ranch_ssl.send(ssl_socket, "PING :test2")

      assert_raise AssertionError, fn ->
        assert_sent_messages([
          {tcp_socket, "PING :test1"},
          {tcp_socket, "PING :test2"},
          {ssl_socket, "PING :test2"},
          {ssl_socket, "PING :test1"}
        ])
      end
    end

    test "raises an error if messages are not sent" do
      {:ok, tcp_socket} = Client.connect(:tcp)
      {:ok, ssl_socket} = Client.connect(:ssl)

      assert_raise AssertionError, fn ->
        assert_sent_messages([
          {tcp_socket, "PING :test"},
          {ssl_socket, "PING :test"}
        ])
      end
    end

    test "raises an error if more messages are sent than expected" do
      {:ok, tcp_socket} = Client.connect(:tcp)
      {:ok, ssl_socket} = Client.connect(:ssl)

      :ranch_tcp.send(tcp_socket, "PING :test")
      :ranch_tcp.send(tcp_socket, "PING :test")
      :ranch_tcp.send(ssl_socket, "PING :test")
      :ranch_tcp.send(ssl_socket, "PING :test")

      assert_raise AssertionError, fn ->
        assert_sent_messages([
          {tcp_socket, "PING :test"},
          {ssl_socket, "PING :test"}
        ])
      end
    end

    test "raises an error if more messages are sent than expected (2)" do
      {:ok, tcp_socket} = Client.connect(:tcp)
      Client.connect(:ssl)

      :ranch_tcp.send(tcp_socket, "PING :test")

      assert_raise AssertionError, fn ->
        assert_sent_messages([])
      end
    end

    test "raises an error if messages are different with validate_order? set to false" do
      {:ok, tcp_socket} = Client.connect(:tcp)
      {:ok, ssl_socket} = Client.connect(:ssl)

      :ranch_tcp.send(tcp_socket, "PING :test1")
      :ranch_tcp.send(tcp_socket, "PING :test2")
      :ranch_ssl.send(ssl_socket, "PING :test1")
      :ranch_ssl.send(ssl_socket, "PING :test2")

      assert_raise AssertionError, fn ->
        assert_sent_messages(
          [
            {tcp_socket, "PING :test2"},
            {tcp_socket, "PING :test1"}
          ],
          validate_order?: false
        )
      end
    end

    test "raises an error if messages are not sent and expected message is a regex" do
      {:ok, tcp_socket} = Client.connect(:tcp)
      {:ok, ssl_socket} = Client.connect(:ssl)

      assert_raise AssertionError, fn ->
        assert_sent_messages([
          {tcp_socket, ~r/^PING/},
          {ssl_socket, ~r/^PING/}
        ])
      end
    end
  end
end
