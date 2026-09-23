defmodule ElixIRCd.Commands.KickTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Kick
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.UserChannels

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
          {user.pid, ":irc.test 442 #{user.nick} #channel :You're not on that channel\r\n"}
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

    test "handles KICK command with kick reason exceeding maximum length" do
      Memento.transaction!(fn ->
        max_kick_message_length = Application.get_env(:elixircd, :channel)[:max_kick_message_length]
        user = insert(:user)
        channel = insert(:channel, name: "#channel")
        insert(:user_channel, user: user, channel: channel, modes: [:o])

        target_user = insert(:user, nick: "target")
        insert(:user_channel, user: target_user, channel: channel)

        too_long_reason = String.duplicate("a", max_kick_message_length + 1)
        message = %Message{command: "KICK", params: ["#channel", "target"], trailing: too_long_reason}
        assert :ok = Kick.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 417 #{user.nick} #channel :Kick reason too long (maximum length is #{max_kick_message_length} characters)\r\n"}
        ])

        # Verify the target user was not kicked
        {:ok, _target_user_channel} = UserChannels.get_by_user_pid_and_channel_name(target_user.pid, channel.name)
      end)
    end

    test "handles KICK command with target user not found" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#channel")
        insert(:user_channel, user: user, channel: channel, modes: [:o])

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
        insert(:user_channel, user: user, channel: channel, modes: [:o])
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
        insert(:user_channel, user: user, channel: channel, modes: [:o])

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
        insert(:user_channel, user: user, channel: channel, modes: [:o])

        target_user = insert(:user, nick: "target")
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "KICK", params: ["#channel", "target"]}
        assert :ok = Kick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} KICK #channel target :#{user.nick}\r\n"},
          {target_user.pid, ":#{user_mask(user)} KICK #channel target :#{user.nick}\r\n"}
        ])
      end)
    end

    test "kicks multiple users from one channel and pairs multiple channel targets" do
      Memento.transaction!(fn ->
        operator = insert(:user, nick: "operator")
        first_channel = insert(:channel, name: "#first")
        second_channel = insert(:channel, name: "#second")

        insert(:user_channel, user: operator, channel: first_channel, modes: [:o])
        insert(:user_channel, user: operator, channel: second_channel, modes: [:o])

        first = insert(:user, nick: "first")
        second = insert(:user, nick: "second")
        third = insert(:user, nick: "third")
        insert(:user_channel, user: first, channel: first_channel)
        insert(:user_channel, user: second, channel: first_channel)
        insert(:user_channel, user: third, channel: second_channel)

        assert :ok =
                 Kick.handle(operator, %Message{
                   command: "KICK",
                   params: ["#first", "first,second"],
                   trailing: "bye"
                 })

        assert :ok =
                 Kick.handle(operator, %Message{
                   command: "KICK",
                   params: ["#first,#second", "operator,third"],
                   trailing: "paired"
                 })

        assert {:error, :user_channel_not_found} =
                 UserChannels.get_by_user_pid_and_channel_name(first.pid, first_channel.name)

        assert {:error, :user_channel_not_found} =
                 UserChannels.get_by_user_pid_and_channel_name(second.pid, first_channel.name)

        assert {:error, :user_channel_not_found} =
                 UserChannels.get_by_user_pid_and_channel_name(third.pid, second_channel.name)

        assert {:error, :user_channel_not_found} =
                 UserChannels.get_by_user_pid_and_channel_name(operator.pid, first_channel.name)
      end)
    end

    test "rejects mismatched multi-target KICK lists" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok =
                 Kick.handle(user, %Message{
                   command: "KICK",
                   params: ["#one,#two", "first,second,third"]
                 })

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} KICK :Not enough parameters\r\n"}
        ])
      end)
    end
  end
end
