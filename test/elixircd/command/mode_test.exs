defmodule ElixIRCd.Command.ModeTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Helper, only: [build_user_mask: 1]

  alias ElixIRCd.Command.Mode
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles MODE command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "MODE", params: ["#anything"]}

        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles MODE command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "MODE", params: []}

        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} MODE :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles MODE command for non-existing channel" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "MODE", params: ["#channel"]}
        Mode.handle(user, message)

        message = %Message{command: "MODE", params: ["#channel", "+t"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 403 #{user.nick} #channel :No such channel\r\n"},
          {user.socket, ":server.example.com 403 #{user.nick} #channel :No such channel\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and user is not in the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)

        message = %Message{command: "MODE", params: [channel.name]}
        Mode.handle(user, message)

        message = %Message{command: "MODE", params: [channel.name, "+t"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 442 #{user.nick} #{channel.name} :You're not on that channel\r\n"},
          {user.socket, ":server.example.com 442 #{user.nick} #{channel.name} :You're not on that channel\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and without mode parameter" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["t", "n", {"l", "10"}])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":#{build_user_mask(user)} MODE #{channel.name} +tnl 10\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and add modes" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["n", {"l", "10"}])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "+t+s"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":#{build_user_mask(user)} MODE #{channel.name} +ts\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and remove modes" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["n", "t", "s", {"l", "10"}])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "-t-s"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":#{build_user_mask(user)} MODE #{channel.name} -ts\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and add modes with value" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["n", {"l", "10"}])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "+t+l+k", "20", "password"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":#{build_user_mask(user)} MODE #{channel.name} +tlk 20 password\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and remove modes with value" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["t", {"l", "20"}, {"k", "password"}])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "-l-k"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":#{build_user_mask(user)} MODE #{channel.name} -lk\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and remove modes with value that do not need value to be removed" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["t", {"l", "20"}, {"k", "password"}])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "-t-l-k"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":#{build_user_mask(user)} MODE #{channel.name} -tlk\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and add modes for user channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        user_operator = insert(:user, nick: "nick_operator")
        user_voice = insert(:user, nick: "nick_voice")
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:user_channel, user: user_operator, channel: channel, modes: [])
        insert(:user_channel, user: user_voice, channel: channel, modes: [])

        message = %Message{command: "MODE", params: [channel.name, "+ov", user_operator.nick, user_voice.nick]}
        Mode.handle(user, message)

        mode_change_message =
          ":#{build_user_mask(user)} MODE #{channel.name} +ov #{user_operator.nick} #{user_voice.nick}\r\n"

        assert_sent_messages([
          {user.socket, mode_change_message},
          {user_operator.socket, mode_change_message},
          {user_voice.socket, mode_change_message}
        ])
      end)
    end

    test "handles MODE command for channel and remove modes for user channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        user_operator = insert(:user, nick: "nick_operator")
        user_voice = insert(:user, nick: "nick_voice")
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:user_channel, user: user_operator, channel: channel, modes: ["o"])
        insert(:user_channel, user: user_voice, channel: channel, modes: ["v"])

        message = %Message{command: "MODE", params: [channel.name, "-ov", user_operator.nick, user_voice.nick]}
        Mode.handle(user, message)

        mode_change_message =
          ":#{build_user_mask(user)} MODE #{channel.name} -ov #{user_operator.nick} #{user_voice.nick}\r\n"

        assert_sent_messages([
          {user.socket, mode_change_message},
          {user_operator.socket, mode_change_message},
          {user_voice.socket, mode_change_message}
        ])
      end)
    end

    test "handles MODE command for channel and add modes for user that is not in the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        user_operator = insert(:user, nick: "nick_operator")
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "+o", user_operator.nick]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket,
           ":server.example.com 441 #{user.nick} #{channel.name} #{user_operator.nick} :They aren't on that channel\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and add modes for user that is not in the server" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "+o", "nonexistent"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 401 #{user.nick} #{channel.name} nonexistent :No such nick\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and add modes for channel ban" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "+b", "nick!user@host"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":#{build_user_mask(user)} MODE #{channel.name} +b nick!user@host\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and remove modes for channel ban" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:channel_ban, channel: channel, mask: "nick!user@host")

        message = %Message{command: "MODE", params: [channel.name, "-b", "nick!user@host"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":#{build_user_mask(user)} MODE #{channel.name} -b nick!user@host\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel to remove modes for channel ban that does not exist" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "-b", "inexistent!@mask"]}
        Mode.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles MODE command for channel to list bans" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        channel_ban = insert(:channel_ban, channel: channel, mask: "nick!user@host")

        message = %Message{command: "MODE", params: [channel.name, "+b"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket,
           ":server.example.com 367 #{user.nick} #{channel.name} #{channel_ban.mask} #{channel_ban.setter} #{DateTime.to_unix(channel_ban.created_at)}\r\n"},
          {user.socket, ":server.example.com 368 #{user.nick} #{channel.name} :End of channel ban list\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel when invalid modes sent" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "+wz"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 472 #{user.nick} w :is unknown mode char to me\r\n"},
          {user.socket, ":server.example.com 472 #{user.nick} z :is unknown mode char to me\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel when no modes changed" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["t"])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "-t"]}
        Mode.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles MODE command for channel when mode changes are missing values" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "+l"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} MODE :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles MODE command for user that is not an operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel)

        message = %Message{command: "MODE", params: [channel.name, "+t"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 482 #{user.nick} #{channel.name} :You're not a channel operator\r\n"}
        ])
      end)
    end

    test "handles MODE command for user and list modes" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "MODE", params: [user.nick]}
        Mode.handle(user, message)
        # Future
      end)
    end

    test "handles MODE command for user and change another user modes" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)

        message = %Message{command: "MODE", params: [another_user.nick, "+i"]}
        Mode.handle(user, message)
        # Future
      end)
    end

    test "handles MODE command for user and add modes" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "MODE", params: [user.nick, "+i", user.nick]}
        Mode.handle(user, message)
        # Future
      end)
    end

    test "handles MODE command for user and remove modes" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "MODE", params: [user.nick, "-i", user.nick]}
        Mode.handle(user, message)
        # Future
      end)
    end
  end
end
