defmodule ElixIRCd.Command.PrivmsgTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  alias ElixIRCd.Command.Privmsg
  alias ElixIRCd.Message

  import ElixIRCd.Factory
  import Mimic

  describe "handle/2" do
    test "handles PRIVMSG command with user not registered" do
      user = insert(:user, identity: nil)
      message = %Message{command: "PRIVMSG", params: ["#anything"]}

      Privmsg.handle(user, message)
      verify!()

      assert_sent_messages([
        {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
      ])
    end

    test "handles PRIVMSG command with not enough parameters" do
      user = insert(:user)

      message = %Message{command: "PRIVMSG", params: []}
      Privmsg.handle(user, message)

      message = %Message{command: "PRIVMSG", params: ["test"], body: nil}
      Privmsg.handle(user, message)

      verify!()

      assert_sent_messages([
        {user.socket, ":server.example.com 461 #{user.nick} PRIVMSG :Not enough parameters\r\n"},
        {user.socket, ":server.example.com 461 #{user.nick} PRIVMSG :Not enough parameters\r\n"}
      ])
    end

    test "handles PRIVMSG command for channel with non-existing channel" do
      user = insert(:user)

      message = %Message{command: "PRIVMSG", params: ["#new_channel"], body: "Hello"}
      Privmsg.handle(user, message)
      verify!()

      assert_sent_messages([
        {user.socket, ":server.example.com 403 #{user.nick} #new_channel :No such channel\r\n"}
      ])
    end

    test "handles PRIVMSG command for channel with existing channel and user is not in the channel" do
      user = insert(:user)
      channel = insert(:channel)

      message = %Message{command: "PRIVMSG", params: [channel.name], body: "Hello"}
      Privmsg.handle(user, message)
      verify!()

      assert_sent_messages([
        {user.socket, ":server.example.com 404 #{user.nick} #{channel.name} :Cannot send to channel\r\n"}
      ])
    end

    test "handles PRIVMSG command for channel with existing channel and user is in the channel with another user" do
      user = insert(:user)
      another_user = insert(:user)
      channel = insert(:channel)
      insert(:user_channel, user: user, channel: channel)
      insert(:user_channel, user: another_user, channel: channel)

      message = %Message{command: "PRIVMSG", params: [channel.name], body: "Hello"}
      Privmsg.handle(user, message)
      verify!()

      assert_sent_messages([
        {another_user.socket, ":#{user.identity} PRIVMSG #{channel.name} :Hello\r\n"}
      ])
    end

    test "handles PRIVMSG command for user with non-existing user" do
      user = insert(:user)

      message = %Message{command: "PRIVMSG", params: ["another_user"], body: "Hello"}
      Privmsg.handle(user, message)
      verify!()

      assert_sent_messages([
        {user.socket, ":server.example.com 401 #{user.nick} another_user :No such nick\r\n"}
      ])
    end

    test "handles PRIVMSG command for user with existing user" do
      user = insert(:user)
      another_user = insert(:user)

      message = %Message{command: "PRIVMSG", params: [another_user.nick], body: "Hello"}
      Privmsg.handle(user, message)
      verify!()

      assert_sent_messages([
        {another_user.socket, ":#{user.identity} PRIVMSG #{another_user.nick} :Hello\r\n"}
      ])
    end
  end
end
