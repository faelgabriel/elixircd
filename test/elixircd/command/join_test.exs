defmodule ElixIRCd.Command.JoinTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Join
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles JOIN command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, identity: nil)
        message = %Message{command: "JOIN", params: ["#anything"]}

        Join.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles JOIN command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "JOIN", params: []}

        Join.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} JOIN :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles JOIN command with invalid channel name" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "JOIN", params: ["#invalid.channel.name"]}

        Join.handle(user, message)

        assert_sent_messages([
          {user.socket,
           ":server.example.com 473 #{user.nick} #invalid.channel.name :Cannot join channel: Invalid channel name format\r\n"}
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

        Join.handle(user, message)

        assert_sent_messages([
          {user.socket, ":#{user.identity} JOIN #{channel.name}\r\n"},
          {user.socket, ":server.example.com 332 #{user.nick} #{channel.name} :#{channel.topic}\r\n"},
          {user.socket,
           ":server.example.com 353 = #{user.nick} #{channel.name} :#{user.nick} #{another_user.nick}\r\n"},
          {user.socket, ":server.example.com 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"},
          {another_user.socket, ":#{user.identity} JOIN #{channel.name}\r\n"}
        ])
      end)
    end

    test "handles JOIN command with non-existing channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "JOIN", params: ["#new_channel"]}

        Join.handle(user, message)

        assert_sent_messages([
          {user.socket, ":#{user.identity} JOIN #new_channel\r\n"},
          {user.socket, ":server.example.com MODE #new_channel +o #{user.nick}\r\n"},
          {user.socket, ":server.example.com 332 #{user.nick} #new_channel :Welcome to #new_channel.\r\n"},
          {user.socket, ":server.example.com 353 = #{user.nick} #new_channel :#{user.nick}\r\n"},
          {user.socket, ":server.example.com 366 #{user.nick} #new_channel :End of NAMES list.\r\n"}
        ])
      end)
    end
  end
end
