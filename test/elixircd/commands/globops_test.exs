defmodule ElixIRCd.Commands.GlobopsTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Globops
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles GLOBOPS command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "GLOBOPS", params: [], trailing: "test message"}

        assert :ok = Globops.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles GLOBOPS command with no message" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        message = %Message{command: "GLOBOPS", params: [], trailing: nil}

        assert :ok = Globops.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} GLOBOPS :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles GLOBOPS command with user not operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "GLOBOPS", params: [], trailing: "test message"}

        assert :ok = Globops.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 481 #{user.nick} :Permission Denied- You're not an IRC operator\r\n"}
        ])
      end)
    end

    test "handles GLOBOPS command with operator user and broadcasts to all operators" do
      Memento.transaction!(fn ->
        sender = insert(:user, modes: ["o"])
        operator1 = insert(:user, modes: ["o"])
        operator2 = insert(:user, modes: ["o"])
        regular_user = insert(:user)
        message = %Message{command: "GLOBOPS", params: [], trailing: "Network maintenance in 10 minutes"}

        assert :ok = Globops.handle(sender, message)

        # All operators should receive the message as GLOBOPS from sender
        assert_sent_messages([
          {sender.pid, ":#{user_mask(sender)} GLOBOPS :Network maintenance in 10 minutes\r\n"},
          {operator1.pid, ":#{user_mask(sender)} GLOBOPS :Network maintenance in 10 minutes\r\n"},
          {operator2.pid, ":#{user_mask(sender)} GLOBOPS :Network maintenance in 10 minutes\r\n"}
        ])

        # Regular user should not receive any messages
        assert_sent_messages_amount(regular_user.pid, 0)
      end)
    end

    test "handles GLOBOPS command with empty message" do
      Memento.transaction!(fn ->
        sender = insert(:user, modes: ["o"])
        operator1 = insert(:user, modes: ["o"])
        message = %Message{command: "GLOBOPS", params: [], trailing: ""}

        assert :ok = Globops.handle(sender, message)

        # Empty message should still be sent
        assert_sent_messages([
          {sender.pid, ":#{user_mask(sender)} GLOBOPS :\r\n"},
          {operator1.pid, ":#{user_mask(sender)} GLOBOPS :\r\n"}
        ])
      end)
    end

    test "handles GLOBOPS when only sender is operator" do
      Memento.transaction!(fn ->
        sender = insert(:user, modes: ["o"])
        regular_user = insert(:user)
        message = %Message{command: "GLOBOPS", params: [], trailing: "Solo operator message"}

        assert :ok = Globops.handle(sender, message)

        # Only sender should receive the message
        assert_sent_messages([
          {sender.pid, ":#{user_mask(sender)} GLOBOPS :Solo operator message\r\n"}
        ])

        # Regular user should not receive any messages
        assert_sent_messages_amount(regular_user.pid, 0)
      end)
    end
  end
end
