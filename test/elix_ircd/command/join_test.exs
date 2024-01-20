defmodule ElixIRCd.Command.JoinTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  doctest ElixIRCd.Command.Join

  alias ElixIRCd.Command.Join
  alias ElixIRCd.Message

  import ElixIRCd.Factory
  import Mimic

  describe "handle/2" do
    test "handles JOIN command with user not registered" do
      user = insert(:user, identity: nil)
      message = %Message{command: "JOIN", params: ["#anything"]}

      Join.handle(user, message)
      verify!()

      assert_sent_messages([
        {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
      ])
    end

    test "handles JOIN command with not enough parameters" do
      user = insert(:user)
      message = %Message{command: "JOIN", params: []}

      Join.handle(user, message)
      verify!()

      assert_sent_messages([
        {user.socket, ":server.example.com 461 #{user.nick} JOIN :Not enough parameters\r\n"}
      ])
    end

    test "handles JOIN command with invalid channel name" do
      user = insert(:user)
      message = %Message{command: "JOIN", params: ["#invalid.channel.name"]}

      Join.handle(user, message)
      verify!()

      assert_sent_messages([
        {user.socket,
         ":server.example.com 473 #{user.nick} #invalid.channel.name :Cannot join channel: Invalid channel name format\r\n"}
      ])
    end

    test "handles JOIN command with existing channel and another user" do
      channel = insert(:channel)
      user_channel = insert(:user_channel, user: insert(:user), channel: channel)

      user = insert(:user)
      message = %Message{command: "JOIN", params: [channel.name]}

      Join.handle(user, message)
      verify!()

      assert_sent_messages([
        {user.socket, ":#{user.identity} JOIN #{channel.name}\r\n"},
        {user_channel.user.socket, ":#{user.identity} JOIN #{channel.name}\r\n"},
        {user.socket, ":server.example.com 332 #{user.nick} #{channel.name} :#{channel.topic}\r\n"},
        {user.socket,
         ":server.example.com 353 = #{user.nick} #{channel.name} :#{user.nick} #{user_channel.user.nick}\r\n"},
        {user.socket, ":server.example.com 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"}
      ])
    end

    test "handles JOIN command with non-existing channel" do
      user = insert(:user)
      message = %Message{command: "JOIN", params: ["#new_channel"]}

      Join.handle(user, message)
      verify!()

      assert_sent_messages([
        {user.socket, ":#{user.identity} JOIN #new_channel\r\n"},
        {user.socket, ":server.example.com 332 #{user.nick} #new_channel :Welcome to #new_channel.\r\n"},
        {user.socket, ":server.example.com 353 = #{user.nick} #new_channel :#{user.nick}\r\n"},
        {user.socket, ":server.example.com 366 #{user.nick} #new_channel :End of NAMES list.\r\n"},
        {user.socket, ":server.example.com MODE #new_channel +o #{user.nick}\r\n"}
      ])
    end
  end
end
