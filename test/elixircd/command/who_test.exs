defmodule ElixIRCd.Command.WhoTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Who
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles WHO command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "WHO", params: ["#anything"]}

        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles WHO command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHO", params: []}

        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} WHO :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles WHO command with inexistent channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHO", params: ["#anything"]}

        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 315 #{user.nick} #anything :End of WHO list\r\n"}
        ])
      end)
    end

    test "handles WHO command with channel target and user shares channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)
        insert(:user_channel, channel: channel, user: user)

        another_user1 = insert(:user, modes: ["o"])
        another_user2 = insert(:user, modes: ["o"])
        another_user3 = insert(:user, modes: ["i"])
        another_user4 = insert(:user, away_message: "away")
        insert(:user_channel, channel: channel, user: another_user1)
        insert(:user_channel, channel: channel, user: another_user2, modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user3, modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user4, modes: ["v"])

        message = %Message{command: "WHO", params: [channel.name]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.socket,
             ":server.example.com 352 #{user.nick} #{channel.name} username hostname server.example.com #{another_user1.nick} H* :0 realname\r\n"},
            {user.socket,
             ":server.example.com 352 #{user.nick} #{channel.name} username hostname server.example.com #{another_user2.nick} H*@ :0 realname\r\n"},
            {user.socket,
             ":server.example.com 352 #{user.nick} #{channel.name} username hostname server.example.com #{another_user3.nick} H@ :0 realname\r\n"},
            {user.socket,
             ":server.example.com 352 #{user.nick} #{channel.name} username hostname server.example.com #{another_user4.nick} G+ :0 realname\r\n"},
            {user.socket,
             ":server.example.com 352 #{user.nick} #{channel.name} username hostname server.example.com #{user.nick} H :0 realname\r\n"},
            {user.socket, ":server.example.com 315 #{user.nick} #{channel.name} :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "handles WHO command with channel target and user does not share channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)

        another_user1 = insert(:user, modes: ["o"])
        another_user2 = insert(:user, modes: ["o"])
        another_user3 = insert(:user, modes: ["i"])
        another_user4 = insert(:user, away_message: "away")
        insert(:user_channel, channel: channel, user: another_user1)
        insert(:user_channel, channel: channel, user: another_user2, modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user3, modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user4, modes: ["v"])

        message = %Message{command: "WHO", params: [channel.name]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.socket,
             ":server.example.com 352 #{user.nick} #{channel.name} username hostname server.example.com #{another_user1.nick} H* :0 realname\r\n"},
            {user.socket,
             ":server.example.com 352 #{user.nick} #{channel.name} username hostname server.example.com #{another_user2.nick} H*@ :0 realname\r\n"},
            {user.socket,
             ":server.example.com 352 #{user.nick} #{channel.name} username hostname server.example.com #{another_user4.nick} G+ :0 realname\r\n"},
            {user.socket, ":server.example.com 315 #{user.nick} #{channel.name} :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "handles WHO command with channel target and user shares secret channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["s"])
        insert(:user_channel, channel: channel, user: user)

        another_user1 = insert(:user)
        another_user2 = insert(:user, modes: ["i"])
        insert(:user_channel, channel: channel, user: another_user1)
        insert(:user_channel, channel: channel, user: another_user2)

        message = %Message{command: "WHO", params: [channel.name]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.socket,
             ":server.example.com 352 #{user.nick} #{channel.name} username hostname server.example.com #{another_user1.nick} H :0 realname\r\n"},
            {user.socket,
             ":server.example.com 352 #{user.nick} #{channel.name} username hostname server.example.com #{another_user2.nick} H :0 realname\r\n"},
            {user.socket,
             ":server.example.com 352 #{user.nick} #{channel.name} username hostname server.example.com #{user.nick} H :0 realname\r\n"},
            {user.socket, ":server.example.com 315 #{user.nick} #{channel.name} :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "handles WHO command with channel target and user does not share secret channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["s"])

        another_user1 = insert(:user)
        another_user2 = insert(:user, modes: ["i"])
        insert(:user_channel, channel: channel, user: another_user1)
        insert(:user_channel, channel: channel, user: another_user2)

        message = %Message{command: "WHO", params: [channel.name]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [{user.socket, ":server.example.com 315 #{user.nick} #{channel.name} :End of WHO list\r\n"}],
          validate_order?: false
        )
      end)
    end

    #
    #
    #
    #
    test "handles WHO command with mask target and user shares channel" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "anick1")
        channel = insert(:channel)
        insert(:user_channel, channel: channel, user: user)

        another_user1 = insert(:user, nick: "anick2", modes: ["o"])
        another_user2 = insert(:user, nick: "anick3", modes: ["o"])
        another_user3 = insert(:user, nick: "anick4", modes: ["i"])
        another_user4 = insert(:user, nick: "anick5", away_message: "away")
        insert(:user_channel, channel: channel, user: another_user1)
        insert(:user_channel, channel: channel, user: another_user2, modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user3, modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user4, modes: ["v"])

        message = %Message{command: "WHO", params: ["anick*"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.socket,
             ":server.example.com 352 #{user.nick} * username hostname server.example.com #{another_user1.nick} H* :0 realname\r\n"},
            {user.socket,
             ":server.example.com 352 #{user.nick} * username hostname server.example.com #{another_user2.nick} H* :0 realname\r\n"},
            {user.socket,
             ":server.example.com 352 #{user.nick} * username hostname server.example.com #{another_user3.nick} H :0 realname\r\n"},
            {user.socket,
             ":server.example.com 352 #{user.nick} * username hostname server.example.com #{another_user4.nick} G :0 realname\r\n"},
            {user.socket,
             ":server.example.com 352 #{user.nick} * username hostname server.example.com #{user.nick} H :0 realname\r\n"},
            {user.socket, ":server.example.com 315 #{user.nick} anick* :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "handles WHO command with mask target and user does not share channel" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "anick1")
        channel = insert(:channel)

        another_user1 = insert(:user, nick: "anick2", modes: ["o"])
        another_user2 = insert(:user, nick: "anick3", modes: ["o"])
        another_user3 = insert(:user, nick: "anick4", modes: ["i"])
        another_user4 = insert(:user, nick: "anick5", away_message: "away")
        insert(:user_channel, channel: channel, user: another_user1)
        insert(:user_channel, channel: channel, user: another_user2, modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user3, modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user4, modes: ["v"])

        message = %Message{command: "WHO", params: ["anick*"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.socket,
             ":server.example.com 352 #{user.nick} * username hostname server.example.com #{another_user1.nick} H* :0 realname\r\n"},
            {user.socket,
             ":server.example.com 352 #{user.nick} * username hostname server.example.com #{another_user2.nick} H* :0 realname\r\n"},
            {user.socket,
             ":server.example.com 352 #{user.nick} * username hostname server.example.com #{another_user4.nick} G :0 realname\r\n"},
            {user.socket,
             ":server.example.com 352 #{user.nick} * username hostname server.example.com #{user.nick} H :0 realname\r\n"},
            {user.socket, ":server.example.com 315 #{user.nick} anick* :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "handles WHO command with mask target and user shares secret channel" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "anick1")
        channel = insert(:channel, modes: ["s"])
        insert(:user_channel, channel: channel, user: user)

        another_user1 = insert(:user, nick: "anick2")
        another_user2 = insert(:user, nick: "anick3", modes: ["i"])
        insert(:user_channel, channel: channel, user: another_user1)
        insert(:user_channel, channel: channel, user: another_user2)

        message = %Message{command: "WHO", params: ["anick*"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.socket,
             ":server.example.com 352 #{user.nick} * username hostname server.example.com #{another_user1.nick} H :0 realname\r\n"},
            {user.socket,
             ":server.example.com 352 #{user.nick} * username hostname server.example.com #{another_user2.nick} H :0 realname\r\n"},
            {user.socket,
             ":server.example.com 352 #{user.nick} * username hostname server.example.com #{user.nick} H :0 realname\r\n"},
            {user.socket, ":server.example.com 315 #{user.nick} anick* :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "handles WHO command with mask target, user shares channel and resolves channel name visibility" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)
        insert(:user_channel, channel: channel, user: user)

        another_user1 = insert(:user, nick: "anick2", modes: ["i", "o"])
        insert(:user_channel, channel: channel, user: another_user1, modes: ["o"])

        message = %Message{command: "WHO", params: ["anick*"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.socket,
             ":server.example.com 352 #{user.nick} #{channel.name} username hostname server.example.com #{another_user1.nick} H*@ :0 realname\r\n"},
            {user.socket, ":server.example.com 315 #{user.nick} anick* :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "handles WHO command with mask target, user does not share channel and resolves channel name visibility" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)

        another_user1 = insert(:user, nick: "anick2", modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user1, modes: ["o"])

        message = %Message{command: "WHO", params: ["anick*"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.socket,
             ":server.example.com 352 #{user.nick} #{channel.name} username hostname server.example.com #{another_user1.nick} H*@ :0 realname\r\n"},
            {user.socket, ":server.example.com 315 #{user.nick} anick* :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "handles WHO command with mask target, user does not share channel and does not resolve channel name visibility" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["s"])

        another_user1 = insert(:user, nick: "anick2")
        insert(:user_channel, channel: channel, user: another_user1, modes: ["o"])

        message = %Message{command: "WHO", params: ["anick*"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.socket,
             ":server.example.com 352 #{user.nick} * username hostname server.example.com #{another_user1.nick} H :0 realname\r\n"},
            {user.socket, ":server.example.com 315 #{user.nick} anick* :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end
  end
end
