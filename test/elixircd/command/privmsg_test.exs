defmodule ElixIRCd.Command.PrivmsgTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Helper, only: [build_user_mask: 1]

  alias ElixIRCd.Command.Privmsg
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles PRIVMSG command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "PRIVMSG", params: ["#anything"]}

        Privmsg.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "PRIVMSG", params: []}
        Privmsg.handle(user, message)

        message = %Message{command: "PRIVMSG", params: ["test"], trailing: nil}
        Privmsg.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} PRIVMSG :Not enough parameters\r\n"},
          {user.socket, ":server.example.com 461 #{user.nick} PRIVMSG :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for channel with non-existing channel" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "PRIVMSG", params: ["#new_channel"], trailing: "Hello"}
        Privmsg.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 403 #{user.nick} #new_channel :No such channel\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for channel with moderated mode and user is not voice or higher" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["m"])
        insert(:user_channel, user: user, channel: channel)

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        Privmsg.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 404 #{user.nick} #{channel.name} :Cannot send to channel\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for channel with no external messages mode and user is not in the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["n"])

        message = %Message{command: "PRIVMSG", params: [channel.name], trailing: "Hello"}
        Privmsg.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 404 #{user.nick} #{channel.name} :Cannot send to channel\r\n"}
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
        Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.socket, ":#{build_user_mask(user)} PRIVMSG #{channel.name} :Hello\r\n"}
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
        Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.socket, ":#{build_user_mask(user)} PRIVMSG #{channel.name} :Hello\r\n"}
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
        Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.socket, ":#{build_user_mask(user)} PRIVMSG #{channel.name} :Hello\r\n"}
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
        Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.socket, ":#{build_user_mask(user)} PRIVMSG #{channel.name} :Hello\r\n"}
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
        Privmsg.handle(user, message)

        assert_sent_messages([
          {another_user.socket, ":#{build_user_mask(user)} PRIVMSG #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for user with non-existing user" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "PRIVMSG", params: ["another_user"], trailing: "Hello"}
        Privmsg.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 401 #{user.nick} another_user :No such nick\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for user with existing user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user)

        message = %Message{command: "PRIVMSG", params: [target_user.nick], trailing: "Hello"}
        Privmsg.handle(user, message)

        assert_sent_messages([
          {target_user.socket, ":#{build_user_mask(user)} PRIVMSG #{target_user.nick} :Hello\r\n"}
        ])
      end)
    end

    test "handles PRIVMSG command for user with existing away user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, away_message: "I'm away")

        message = %Message{command: "PRIVMSG", params: [target_user.nick], trailing: "Hello"}
        Privmsg.handle(user, message)

        assert_sent_messages([
          {target_user.socket, ":#{build_user_mask(user)} PRIVMSG #{target_user.nick} :Hello\r\n"},
          {user.socket, ":server.example.com 301 #{user.nick} #{target_user.nick} :I'm away\r\n"}
        ])
      end)
    end
  end
end
