defmodule ElixIRCd.Command.KillTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Helper, only: [get_user_mask: 1]

  alias ElixIRCd.Command.Kill
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles KILL command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "KILL", params: ["#anything"]}

        assert :ok = Kill.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles KILL command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "KILL", params: []}

        assert :ok = Kill.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} KILL :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles KILL command with user not operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "KILL", params: ["target"], trailing: "reason"}

        assert :ok = Kill.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 481 #{user.nick} :Permission Denied- You're not an IRC operator\r\n"}
        ])
      end)
    end

    test "handles KILL command with target user not found" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        message = %Message{command: "KILL", params: ["target"], trailing: "reason"}

        assert :ok = Kill.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 401 #{user.nick} target :No such nick\r\n"}
        ])
      end)
    end

    test "handles KILL command with target user found and reason" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        target_user = insert(:user)
        message = %Message{command: "KILL", params: [target_user.nick], trailing: "Kill reason"}

        assert :ok = Kill.handle(user, message)

        expected_killed_message = "Killed (#{user.nick} (Kill reason))"
        expected_target_user_socket = target_user.socket

        assert_sent_messages([
          {target_user.socket,
           ":server.example.com ERROR :Closing Link: #{get_user_mask(target_user)} (#{expected_killed_message})\r\n"}
        ])

        assert_received {:disconnect, ^expected_target_user_socket, ^expected_killed_message}
      end)
    end

    test "handles KILL command with target user found and no reason" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        target_user = insert(:user)
        message = %Message{command: "KILL", params: [target_user.nick]}

        assert :ok = Kill.handle(user, message)

        expected_killed_message = "Killed (#{user.nick})"
        expected_target_user_socket = target_user.socket

        assert_sent_messages([
          {target_user.socket,
           ":server.example.com ERROR :Closing Link: #{get_user_mask(target_user)} (#{expected_killed_message})\r\n"}
        ])

        assert_received {:disconnect, ^expected_target_user_socket, ^expected_killed_message}
      end)
    end
  end
end
