defmodule ElixIRCd.Commands.KillTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Kill
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles KILL command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "KILL", params: ["#anything"]}

        assert :ok = Kill.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles KILL command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "KILL", params: []}

        assert :ok = Kill.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} KILL :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles KILL command with user not operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "KILL", params: ["target"], trailing: "reason"}

        assert :ok = Kill.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 481 #{user.nick} :Permission Denied- You're not an IRC operator\r\n"}
        ])
      end)
    end

    test "handles KILL command with target user not found" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        message = %Message{command: "KILL", params: ["target"], trailing: "reason"}

        assert :ok = Kill.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 401 #{user.nick} target :No such nick\r\n"}
        ])
      end)
    end

    test "handles KILL command with target user found and reason" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        # self() as the pid for the target user because of the `assert_received` assertion
        target_user = insert(:user, pid: self())
        message = %Message{command: "KILL", params: [target_user.nick], trailing: "Kill reason"}

        assert :ok = Kill.handle(user, message)

        expected_killed_message = "Killed (#{user.nick} (Kill reason))"

        assert_sent_messages([
          {target_user.pid, ":irc.test ERROR :Closing Link: #{user_mask(target_user)} (#{expected_killed_message})\r\n"}
        ])

        assert_received {:disconnect, ^expected_killed_message}
      end)
    end

    test "handles KILL command with target user found and no reason" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        # self() as the pid for the target user because of the `assert_received` assertion
        target_user = insert(:user, pid: self())
        message = %Message{command: "KILL", params: [target_user.nick]}

        assert :ok = Kill.handle(user, message)

        expected_killed_message = "Killed (#{user.nick})"

        assert_sent_messages([
          {target_user.pid, ":irc.test ERROR :Closing Link: #{user_mask(target_user)} (#{expected_killed_message})\r\n"}
        ])

        assert_received {:disconnect, ^expected_killed_message}
      end)
    end

    test "sends snotice to operators with +s mode when KILL is used" do
      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])
        oper_with_s = insert(:user, modes: ["o", "s"])
        target_user = insert(:user, pid: self())
        message = %Message{command: "KILL", params: [target_user.nick], trailing: "Spam"}

        assert :ok = Kill.handle(oper, message)

        oper_info = "#{oper.nick}!#{oper.ident}@#{oper.hostname} [127.0.0.1]"
        target_info = "#{target_user.nick}!#{target_user.ident}@#{target_user.hostname} [127.0.0.1]"
        expected_snotice = ":irc.test NOTICE :*** Kill: Local kill by #{oper_info} for #{target_info} (Spam)\r\n"

        assert_sent_messages([
          {oper_with_s.pid, expected_snotice}
        ])
      end)
    end
  end
end
