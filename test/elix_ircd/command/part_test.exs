defmodule ElixIRCd.Command.PartTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  alias ElixIRCd.Command.Part
  alias ElixIRCd.Message

  import ElixIRCd.Factory

  describe "handle/2" do
    test "handles PART command with user not registered" do
      user = insert(:user, identity: nil)
      message = %Message{command: "PART", params: ["#anything"]}

      Part.handle(user, message)

      assert_sent_messages([
        {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
      ])
    end

    test "handles PART command with not enough parameters" do
      user = insert(:user)
      message = %Message{command: "PART", params: []}

      Part.handle(user, message)

      assert_sent_messages([
        {user.socket, ":server.example.com 461 #{user.nick} PART :Not enough parameters\r\n"}
      ])
    end

    test "handles PART command with non-existing channel" do
      user = insert(:user)
      message = %Message{command: "PART", params: ["#new_channel"]}

      Part.handle(user, message)

      assert_sent_messages([
        {user.socket, ":server.example.com 403 #{user.nick} #new_channel :No such channel\r\n"}
      ])
    end

    test "handles PART command with existing channel and user is not in the channel" do
      user = insert(:user)
      channel = insert(:channel)

      message = %Message{command: "PART", params: [channel.name]}

      Part.handle(user, message)

      assert_sent_messages([
        {user.socket, ":server.example.com 442 #{user.nick} #{channel.name} :You're not on that channel\r\n"}
      ])
    end

    test "handles PART command with existing channel and user is in the channel with another user" do
      user = insert(:user)
      another_user = insert(:user)
      channel = insert(:channel)

      insert(:user_channel, user: user, channel: channel)
      insert(:user_channel, user: another_user, channel: channel)

      message = %Message{command: "PART", params: [channel.name]}

      Part.handle(user, message)

      assert_sent_messages([
        {user.socket, ":#{user.identity} PART #{channel.name}\r\n"},
        {another_user.socket, ":#{user.identity} PART #{channel.name}\r\n"}
      ])
    end
  end
end
