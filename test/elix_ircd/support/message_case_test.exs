defmodule ElixIRCd.MessageCaseTest do
  @moduledoc false

  use ElixIRCd.MessageCase, async: false

  alias ElixIRCd.Client
  alias ExUnit.AssertionError

  describe "assert_sent_messages/1" do
    test "passes if messages are sent" do
      {:ok, tcp_socket} = Client.connect(:tcp)
      {:ok, ssl_socket} = Client.connect(:ssl)

      :ranch_tcp.send(tcp_socket, "PING :test")
      :ranch_ssl.send(ssl_socket, "PING :test")

      assert_sent_messages([
        {tcp_socket, "PING :test"},
        {ssl_socket, "PING :test"}
      ])
    end

    test "raises an error if messages are not sent" do
      {:ok, tcp_socket} = Client.connect(:tcp)
      {:ok, ssl_socket} = Client.connect(:ssl)

      assert_raise AssertionError, fn ->
        assert_sent_messages([
          {tcp_socket, "PING :test"},
          {ssl_socket, "PING :test"},
          {tcp_socket, "PING :test"},
          {ssl_socket, "PING :test"}
        ])
      end
    end
  end
end
