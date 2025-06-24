defmodule ElixIRCd.Commands.OperWallTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Operwall
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles OPERWALL command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "OPERWALL", params: [], trailing: "test message"}

        assert :ok = Operwall.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles OPERWALL command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        message = %Message{command: "OPERWALL", params: []}

        assert :ok = Operwall.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} OPERWALL :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles OPERWALL command with trailing parameter as nil" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        message = %Message{command: "OPERWALL", params: [], trailing: nil}

        assert :ok = Operwall.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} OPERWALL :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles OPERWALL command with user not operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "OPERWALL", params: [], trailing: "test message"}

        assert :ok = Operwall.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 481 #{user.nick} :Permission Denied- You're not an IRC operator\r\n"}
        ])
      end)
    end

    test "handles OPERWALL command with operator user and message" do
      Memento.transaction!(fn ->
        sender = insert(:user, modes: ["o"])
        operator1 = insert(:user, modes: ["o"])
        operator2 = insert(:user, modes: ["o"])
        regular_user = insert(:user)
        message = %Message{command: "OPERWALL", params: [], trailing: "Server maintenance in 10 minutes"}

        assert :ok = Operwall.handle(sender, message)

        # All operators should receive the message, including the sender
        assert_sent_messages([
          {sender.pid, ":irc.test NOTICE $opers :Server maintenance in 10 minutes\r\n"},
          {operator1.pid, ":irc.test NOTICE $opers :Server maintenance in 10 minutes\r\n"},
          {operator2.pid, ":irc.test NOTICE $opers :Server maintenance in 10 minutes\r\n"}
        ])

        # Regular user should not receive any messages
        assert_sent_messages_amount(regular_user.pid, 0)
      end)
    end
  end
end
