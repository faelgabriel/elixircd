defmodule ElixIRCd.MessageCaseTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  alias ElixIRCd.Client
  alias ExUnit.AssertionError

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

      Client.disconnect(tcp_socket)
      Client.disconnect(ssl_socket)
    end

    test "raises an error messages are not sent in the correct order" do
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

      Client.disconnect(tcp_socket)
      Client.disconnect(ssl_socket)
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

      Client.disconnect(tcp_socket)
      Client.disconnect(ssl_socket)
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

      Client.disconnect(tcp_socket)
      Client.disconnect(ssl_socket)
    end
  end
end
