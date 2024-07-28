defmodule ElixIRCd.Command.TraceTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import Mimic

  alias ElixIRCd.Command.Trace
  alias ElixIRCd.Helper
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles TRACE command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "TRACE", params: ["#anything"]}

        assert :ok = Trace.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles TRACE command without target" do
      Helper
      |> expect(:get_socket_ip, 2, fn _socket -> {:ok, {127, 0, 0, 1}} end)

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "TRACE", params: []}

        assert :ok = Trace.handle(user, message)

        assert_sent_messages([
          {user.socket,
           ~r{:server\.example\.com 205 #{user.nick} User users #{user.nick}\[.*\] \(127\.0\.0\.1\) \d+ \d+\r\n}},
          {user.socket, ":server.example.com 262 #{user.nick} :End of TRACE\r\n"}
        ])
      end)
    end

    test "handles TRACE command with target user" do
      Helper
      |> expect(:get_socket_ip, 2, fn _socket -> {:ok, {127, 0, 0, 1}} end)

      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target")
        message = %Message{command: "TRACE", params: ["target"]}

        assert :ok = Trace.handle(user, message)

        assert_sent_messages([
          {user.socket,
           ~r{:server\.example\.com 205 #{user.nick} User users #{target_user.nick}\[.*\] \(127\.0\.0\.1\) \d+ \d+\r\n}},
          {user.socket, ":server.example.com 262 #{user.nick} :End of TRACE\r\n"}
        ])
      end)
    end

    test "handles TRACE command with target user not existing" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "TRACE", params: ["target"]}

        assert :ok = Trace.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 401 #{user.nick} target :No such nick\r\n"}
        ])
      end)
    end

    test "handle TRACE command wth target user socket is not connected (user disconnected in the meantime)" do
      Helper
      |> expect(:get_socket_ip, 2, fn _socket -> {:error, "anyerror"} end)

      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user)
        message = %Message{command: "TRACE", params: [target_user.nick]}

        assert :ok = Trace.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 401 #{user.nick} #{target_user.nick} :No such nick\r\n"}
        ])
      end)
    end
  end
end
