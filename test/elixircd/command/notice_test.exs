defmodule ElixIRCd.Command.NoticeTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  alias ElixIRCd.Command.Notice
  alias ElixIRCd.Message

  import ElixIRCd.Factory

  describe "handle/2" do
    test "handles NOTICE command with user not registered" do
      Memento.transaction(fn ->
        user = insert(:user, identity: nil)
        message = %Message{command: "NOTICE", params: ["#anything"]}

        Notice.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles NOTICE command with not enough parameters" do
      Memento.transaction(fn ->
        user = insert(:user)

        message = %Message{command: "NOTICE", params: []}
        Notice.handle(user, message)

        message = %Message{command: "NOTICE", params: ["test"], trailing: nil}
        Notice.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} NOTICE :Not enough parameters\r\n"},
          {user.socket, ":server.example.com 461 #{user.nick} NOTICE :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles NOTICE command for channel with non-existing channel" do
      Memento.transaction(fn ->
        user = insert(:user)

        message = %Message{command: "NOTICE", params: ["#new_channel"], trailing: "Hello"}
        Notice.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 403 #{user.nick} #new_channel :No such channel\r\n"}
        ])
      end)
    end

    test "handles NOTICE command for channel with existing channel and user is not in the channel" do
      Memento.transaction(fn ->
        user = insert(:user)
        channel = insert(:channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        Notice.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 404 #{user.nick} #{channel.name} :Cannot send to channel\r\n"}
        ])
      end)
    end

    test "handles NOTICE command for channel with existing channel and user is in the channel with another user" do
      Memento.transaction(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel)
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        Notice.handle(user, message)

        assert_sent_messages([
          {another_user.socket, ":#{user.identity} NOTICE #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "handles NOTICE command for user with non-existing user" do
      Memento.transaction(fn ->
        user = insert(:user)

        message = %Message{command: "NOTICE", params: ["another_user"], trailing: "Hello"}
        Notice.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 401 #{user.nick} another_user :No such nick\r\n"}
        ])
      end)
    end

    test "handles NOTICE command for user with existing user" do
      Memento.transaction(fn ->
        user = insert(:user)
        another_user = insert(:user)

        message = %Message{command: "NOTICE", params: [another_user.nick], trailing: "Hello"}
        Notice.handle(user, message)

        assert_sent_messages([
          {another_user.socket, ":#{user.identity} NOTICE #{another_user.nick} :Hello\r\n"}
        ])
      end)
    end
  end
end
