defmodule ElixIRCd.Commands.KickTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Kick
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles KICK command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "KICK", params: ["#anything"]}

        assert :ok = Kick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles KICK command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "KICK", params: []}
        assert :ok = Kick.handle(user, message)

        message = %Message{command: "KICK", params: ["#only_channel_name"]}
        assert :ok = Kick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} KICK :Not enough parameters\r\n"},
          {user.pid, ":irc.test 461 #{user.nick} KICK :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles KICK command with channel not found" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "KICK", params: ["#nonexistent", "target"]}
        assert :ok = Kick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 403 #{user.nick} #nonexistent :No such channel\r\n"}
        ])
      end)
    end

    test "handles KICK command with user not in channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        insert(:channel, name: "#channel")

        message = %Message{command: "KICK", params: ["#channel", "target"]}
        assert :ok = Kick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 441 #{user.nick} #channel :You're not on that channel\r\n"}
        ])
      end)
    end

    test "handles KICK command with user not operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#channel")
        insert(:user_channel, user: user, channel: channel)

        message = %Message{command: "KICK", params: ["#channel", "target"]}
        assert :ok = Kick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 482 #{user.nick} #channel :You're not channel operator\r\n"}
        ])
      end)
    end

    test "handles KICK command with target user not found" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#channel")
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "KICK", params: ["#channel", "target"]}
        assert :ok = Kick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 401 #{user.nick} target :No such nick/channel\r\n"}
        ])
      end)
    end

    test "handles KICK command with target user not in channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#channel")
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:user, nick: "target")

        message = %Message{command: "KICK", params: ["#channel", "target"]}
        assert :ok = Kick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 441 #{user.nick} #channel :They aren't on that channel\r\n"}
        ])
      end)
    end

    test "handles KICK command with target user kicked with reason" do
      Memento.transaction(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#channel")
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        target_user = insert(:user, nick: "target")
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "KICK", params: ["#channel", "target"], trailing: "reason"}
        assert :ok = Kick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} KICK #channel target :reason\r\n"},
          {target_user.pid, ":#{user_mask(user)} KICK #channel target :reason\r\n"}
        ])
      end)
    end

    test "handles KICK command with target user kicked without reason" do
      Memento.transaction(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#channel")
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        target_user = insert(:user, nick: "target")
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "KICK", params: ["#channel", "target"]}
        assert :ok = Kick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} KICK #channel target\r\n"},
          {target_user.pid, ":#{user_mask(user)} KICK #channel target\r\n"}
        ])
      end)
    end
  end
end
