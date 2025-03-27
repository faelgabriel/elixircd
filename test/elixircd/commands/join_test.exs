defmodule ElixIRCd.Commands.JoinTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Join
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles JOIN command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "JOIN", params: ["#anything"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles JOIN command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "JOIN", params: []}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 461 #{user.nick} JOIN :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles JOIN command with invalid channel name" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "JOIN", params: ["#invalid.channel.name"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":server.example.com 476 #{user.nick} #invalid.channel.name :Cannot join channel - invalid channel name format\r\n"}
        ])
      end)
    end

    test "handles JOIN command with non-existing channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "JOIN", params: ["#new_channel"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #new_channel\r\n"},
          {user.pid, ":server.example.com MODE #new_channel +o #{user.nick}\r\n"},
          {user.pid, ":server.example.com 331 #{user.nick} #new_channel :No topic is set\r\n"},
          {user.pid, ":server.example.com 353 = #{user.nick} #new_channel :@#{user.nick}\r\n"},
          {user.pid, ":server.example.com 366 #{user.nick} #new_channel :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "handles JOIN command with empty channel key" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [{"k", "password"}])
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 475 #{user.nick} #{channel.name} :Cannot join channel (+k) - bad key\r\n"}
        ])
      end)
    end

    test "handles JOIN command with wrong channel key" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [{"k", "password"}])
        message = %Message{command: "JOIN", params: [channel.name, "wrong_password"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 475 #{user.nick} #{channel.name} :Cannot join channel (+k) - bad key\r\n"}
        ])
      end)
    end

    test "handles JOIN command with channel limit reached" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [{"l", "1"}])
        insert(:user_channel, channel: channel)
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":server.example.com 471 #{user.nick} #{channel.name} :Cannot join channel (+l) - channel is full\r\n"}
        ])
      end)
    end

    test "handles JOIN command with a user banned from the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)
        insert(:channel_ban, channel: channel, mask: "#{user.nick}!*@*")
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":server.example.com 474 #{user.nick} #{channel.name} :Cannot join channel (+b) - you are banned\r\n"}
        ])
      end)
    end

    test "handles JOIN command with a user not invited to the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["i"])
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":server.example.com 473 #{user.nick} #{channel.name} :Cannot join channel (+i) - you are not invited\r\n"}
        ])
      end)
    end

    test "handles JOIN command with correct channel key, available limit, no bans and with user invited" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [{"k", "password"}, {"l", "1"}, "i"])
        insert(:channel_invite, channel: channel, user: user)
        message = %Message{command: "JOIN", params: [channel.name, "password"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":server.example.com 332 #{user.nick} #{channel.name} :topic\r\n"},
          {user.pid, ":server.example.com 353 = #{user.nick} #{channel.name} :#{user.nick}\r\n"},
          {user.pid, ":server.example.com 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "handles JOIN command with existing channel and another user" do
      Memento.transaction!(fn ->
        channel = insert(:channel)
        another_user = insert(:user)
        insert(:user_channel, user: another_user, channel: channel)

        user = insert(:user)
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":server.example.com 332 #{user.nick} #{channel.name} :#{channel.topic.text}\r\n"},
          {user.pid, ":server.example.com 353 = #{user.nick} #{channel.name} :#{user.nick} #{another_user.nick}\r\n"},
          {user.pid, ":server.example.com 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"},
          {another_user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"}
        ])
      end)
    end
  end
end
