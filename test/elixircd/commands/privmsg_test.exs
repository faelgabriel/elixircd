defmodule ElixIRCd.Commands.PrivmsgTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Privmsg
  alias ElixIRCd.Message
  alias ElixIRCd.Service

  describe "handle/2" do
    test "handles PRIVMSG command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "PRIVMSG", params: ["#anything"]}

        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "PRIVMSG", params: []}
        assert :ok = Privmsg.handle(user, message)

        message = %Message{command: "PRIVMSG", params: ["test"], trailing: nil}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} PRIVMSG :Not enough parameters\r\n"},
          {user.pid, ":irc.test 461 #{user.nick} PRIVMSG :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for channel with non-existing channel" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "PRIVMSG", params: ["#new_channel"], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 403 #{user.nick} #new_channel :No such channel\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for channel with moderated mode and user is not voice or higher" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["m"])
        insert(:user_channel, user: user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 404 #{user.nick} #{channel.name} :Cannot send to channel\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for channel with no external messages mode and user is not in the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["n"])

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 404 #{user.nick} #{channel.name} :Cannot send to channel\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for channel with moderated mode and user is voice" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["m"])
        insert(:user_channel, user: user, channel: channel, modes: ["v"])
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for channel with moderated mode and user is operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["m"])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for channel with no external messages mode and user is in the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["n"])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for channel without no external messages mode and user is not in the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for channel with existing channel and user is in the channel with another user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel)
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for user with non-existing user" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "PRIVMSG", params: ["another_user"], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 401 #{user.nick} another_user :No such nick\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for user with existing user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user)

        message = %Message{command: "PRIVMSG", params: [target_user.nick], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {target_user.pid, ":#{user_mask(user)} PRIVMSG #{target_user.nick} :Hello\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for user with existing away user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, away_message: "I'm away")

        message = %Message{command: "PRIVMSG", params: [target_user.nick], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {target_user.pid, ":#{user_mask(user)} PRIVMSG #{target_user.nick} :Hello\r\n"},
          {user.pid, ":irc.test 301 #{user.nick} #{target_user.nick} :I'm away\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for message without trailing but with extra params" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user)

        message = %Message{command: "PRIVMSG", params: [target_user.nick, "Hello", "World"]}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {target_user.pid, ":#{user_mask(user)} PRIVMSG #{target_user.nick} :Hello World\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command directed to a service with trailing message" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "PRIVMSG", params: ["NICKSERV"], trailing: "REGISTER password email@example.com"}

        Service
        |> expect(:service_implemented?, fn "NICKSERV" -> true end)
        |> expect(:dispatch, fn dispatched_user, service, command_list ->
          assert dispatched_user == user
          assert service == "NICKSERV"
          assert command_list == ["REGISTER", "password", "email@example.com"]
          :ok
        end)

        assert :ok = Privmsg.handle(user, message)

        verify!()
      end)
    end

    test "handles PRIVMSG command directed to a service with params instead of trailing" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "PRIVMSG", params: ["NICKSERV", "IDENTIFY", "password"]}

        Service
        |> expect(:service_implemented?, fn "NICKSERV" -> true end)
        |> expect(:dispatch, fn dispatched_user, service, command_list ->
          assert dispatched_user == user
          assert service == "NICKSERV"
          assert command_list == ["IDENTIFY", "password"]
          :ok
        end)

        assert :ok = Privmsg.handle(user, message)

        verify!()
      end)
    end

    test "handles PRIVMSG command with case-insensitive service name" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "PRIVMSG", params: ["nickserv"], trailing: "REGISTER password email@example.com"}

        Service
        |> expect(:service_implemented?, fn "nickserv" -> true end)
        |> expect(:dispatch, fn dispatched_user, service, command_list ->
          assert dispatched_user == user
          assert service == "nickserv"
          assert command_list == ["REGISTER", "password", "email@example.com"]
          :ok
        end)

        assert :ok = Privmsg.handle(user, message)

        verify!()
      end)
    end

    test "handles PRIVMSG command for user with +g mode and sender is not registered (sender gets blocked notification)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user, modes: ["g"])

        message = %Message{command: "PRIVMSG", params: [another_user.nick], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 716 #{user.nick} #{another_user.nick} :Your message has been blocked. #{another_user.nick} is only accepting messages from authorized users.\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for user with +R mode and sender is not registered (sender gets blocked notification)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "TargetUser", modes: ["R"])
        message = %Message{command: "PRIVMSG", params: [target_user.nick], trailing: "Hello"}

        Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 477 #{user.nick} #{target_user.nick} :You must be identified to message this user\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for user with +R mode and sender is registered (target gets message)" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["r"])
        target_user = insert(:user, nick: "TargetUser", modes: ["R"])
        message = %Message{command: "PRIVMSG", params: [target_user.nick], trailing: "Hello"}

        Privmsg.handle(user, message)

        assert_sent_messages([
          {target_user.pid, ":#{user_mask(user)} PRIVMSG #{target_user.nick} :Hello\r\n"}
        ])
      end)
    end

    test "blocks CTCP messages for users not in channel when +C mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["C"])
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "\x01ACTION waves\x01"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 404 #{user.nick} #{channel.name} :Cannot send CTCP to channel (+C)\r\n"}
        ])
      end)
    end

    test "blocks CTCP messages for regular users when +C mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["C"])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "\x01ACTION waves\x01"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 404 #{user.nick} #{channel.name} :Cannot send CTCP to channel (+C)\r\n"}
        ])
      end)
    end

    test "blocks VERSION CTCP messages for regular users when +C mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["C"])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "\x01VERSION\x01"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 404 #{user.nick} #{channel.name} :Cannot send CTCP to channel (+C)\r\n"}
        ])
      end)
    end

    test "allows CTCP messages for channel operators when +C mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["C"])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "\x01ACTION waves\x01"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :\x01ACTION waves\x01\r\n"}
        ])
      end)
    end

    test "allows CTCP messages for voice users when +C mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["C"])
        insert(:user_channel, user: user, channel: channel, modes: ["v"])
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "\x01ACTION dances\x01"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :\x01ACTION dances\x01\r\n"}
        ])
      end)
    end

    test "allows regular messages when +C mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["C"])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello everyone!"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :Hello everyone!\r\n"}
        ])
      end)
    end

    test "allows CTCP messages when +C mode is not set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "\x01ACTION waves\x01"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :\x01ACTION waves\x01\r\n"}
        ])
      end)
    end

    test "handles malformed CTCP messages correctly" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["C"])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "\x01This is not a CTCP"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :\x01This is not a CTCP\r\n"}
        ])
      end)
    end

    test "blocks messages with color codes when +c mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["c"])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "\x03Hello world"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 404 #{user.nick} #{channel.name} :Cannot send to channel (+c - no colors allowed)\r\n"}
        ])
      end)
    end

    test "blocks messages with bold formatting when +c mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["c"])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "\x02Bold text\x02"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 404 #{user.nick} #{channel.name} :Cannot send to channel (+c - no colors allowed)\r\n"}
        ])
      end)
    end

    test "blocks messages with underline formatting when +c mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["c"])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "\x1FUnderlined text\x1F"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 404 #{user.nick} #{channel.name} :Cannot send to channel (+c - no colors allowed)\r\n"}
        ])
      end)
    end

    test "blocks messages with italic formatting when +c mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["c"])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "\x1DItalic text\x1D"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 404 #{user.nick} #{channel.name} :Cannot send to channel (+c - no colors allowed)\r\n"}
        ])
      end)
    end

    test "blocks messages with reverse formatting when +c mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["c"])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "\x16Reverse text\x16"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 404 #{user.nick} #{channel.name} :Cannot send to channel (+c - no colors allowed)\r\n"}
        ])
      end)
    end

    test "blocks messages with multiple formatting codes when +c mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["c"])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "\x02\x03Bold and colored\x0F"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 404 #{user.nick} #{channel.name} :Cannot send to channel (+c - no colors allowed)\r\n"}
        ])
      end)
    end

    test "allows plain text messages when +c mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["c"])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello everyone!"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :Hello everyone!\r\n"}
        ])
      end)
    end

    test "allows formatted messages when +c mode is not set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "\x02Bold text\x02"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :\x02Bold text\x02\r\n"}
        ])
      end)
    end

    test "blocks formatted messages with alternative client format when +c mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["c"])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name, "\x03Red", "text"], trailing: nil}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 404 #{user.nick} #{channel.name} :Cannot send to channel (+c - no colors allowed)\r\n"}
        ])
      end)
    end

    test "allows plain text messages with alternative client format when +c mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["c"])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name, "Plain", "text"], trailing: nil}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :Plain text\r\n"}
        ])
      end)
    end

    test "blocks messages when +d mode is set with +n mode and user just joined" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["n", {"d", "5"}])
        insert(:user_channel, user: user, channel: channel, created_at: DateTime.utc_now())
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 937 #{user.nick} #{channel.name} :You must wait 5 seconds after joining before speaking in this channel.\r\n"}
        ])
      end)
    end

    test "allows messages when +d mode is set with +n mode and enough time has passed" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["n", {"d", "5"}])
        past_time = DateTime.add(DateTime.utc_now(), -10, :second)
        insert(:user_channel, user: user, channel: channel, created_at: past_time)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "allows messages when +d mode is set with +n mode and user is channel operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["n", {"d", "5"}])
        insert(:user_channel, user: user, channel: channel, modes: ["o"], created_at: DateTime.utc_now())
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "allows messages when +d mode is set with +n mode and user has voice" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["n", {"d", "5"}])
        insert(:user_channel, user: user, channel: channel, modes: ["v"], created_at: DateTime.utc_now())
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "allows messages when +d mode is not set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, created_at: DateTime.utc_now())
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "blocks messages when +d mode is set with +n mode and different delay values" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["n", {"d", "10"}])
        insert(:user_channel, user: user, channel: channel, created_at: DateTime.utc_now())
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 937 #{user.nick} #{channel.name} :You must wait 10 seconds after joining before speaking in this channel.\r\n"}
        ])
      end)
    end

    test "allows messages when +d mode is set and +m mode is also set and user has voice and enough time passed" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["m", {"d", "5"}])
        past_time = DateTime.add(DateTime.utc_now(), -10, :second)
        insert(:user_channel, user: user, channel: channel, modes: ["v"], created_at: past_time)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "allows messages when +d mode is set and +m mode is also set and user has voice (voice bypasses delay)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["m", {"d", "5"}])
        insert(:user_channel, user: user, channel: channel, modes: ["v"], created_at: DateTime.utc_now())
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} PRIVMSG #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "blocks messages when +d mode is set and +m mode is also set and user has no voice (blocked by moderation first)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: ["m", {"d", "5"}])
        insert(:user_channel, user: user, channel: channel, created_at: DateTime.utc_now())
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        assert :ok = Privmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 404 #{user.nick} #{channel.name} :Cannot send to channel\r\n"}
        ])
      end)
    end
  end
end
