defmodule ElixIRCd.Commands.TagmsgTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Tagmsg
  alias ElixIRCd.Message

  describe "handle/2 - TAGMSG" do
    test "rejects TAGMSG when user is not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "TAGMSG", params: ["target"]}

        assert :ok = Tagmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "rejects TAGMSG when MESSAGE-TAGS capability is not negotiated" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "TAGMSG", params: ["target"]}

        assert :ok = Tagmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 421 #{user.nick} TAGMSG :Unknown command\r\n"}
        ])
      end)
    end

    test "sends TAGMSG to a user when MESSAGE-TAGS is enabled" do
      Memento.transaction!(fn ->
        sender = insert(:user, capabilities: ["MESSAGE-TAGS"])
        recipient = insert(:user, capabilities: ["MESSAGE-TAGS"])

        message = %Message{command: "TAGMSG", params: [recipient.nick], tags: %{"example" => "1"}}

        assert :ok = Tagmsg.handle(sender, message)

        assert_sent_messages([
          {recipient.pid,
           "@example=1 :#{sender.nick}!#{String.slice(sender.ident, 0..9)}@#{sender.hostname} TAGMSG #{recipient.nick}\r\n"}
        ])
      end)
    end

    test "returns error when no TAGMSG target is provided" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["MESSAGE-TAGS"])
        message = %Message{command: "TAGMSG", params: []}

        assert :ok = Tagmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} TAGMSG :Not enough parameters\r\n"}
        ])
      end)
    end

    test "does not send TAGMSG when target is a service" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["MESSAGE-TAGS"])
        message = %Message{command: "TAGMSG", params: ["NickServ"], tags: %{"example" => "1"}}

        assert :ok = Tagmsg.handle(user, message)

        # Nenhuma mensagem é enviada, TAGMSG para serviço é ignorado.
        assert_sent_messages([])
      end)
    end

    test "sends TAGMSG to a channel when user is joined and channel allows sending" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["MESSAGE-TAGS"])
        channel = insert(:channel, name: "#chan", modes: [])

        # Usuário remetente e outro usuário no canal
        other_user = insert(:user, capabilities: ["MESSAGE-TAGS"])
        insert(:user_channel, user: user, channel: channel, modes: [])
        insert(:user_channel, user: other_user, channel: channel, modes: [])

        message = %Message{command: "TAGMSG", params: [channel.name], tags: %{"example" => "1"}}

        assert :ok = Tagmsg.handle(user, message)

        assert_sent_messages([
          {other_user.pid,
           "@example=1 :#{user.nick}!#{String.slice(user.ident, 0..9)}@#{user.hostname} TAGMSG #chan\r\n"}
        ])
      end)
    end

    test "sends TAGMSG in moderated channel when user is operator and no delay is configured" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["MESSAGE-TAGS"])
        channel = insert(:channel, name: "#staff", modes: ["m"])

        other_user = insert(:user, capabilities: ["MESSAGE-TAGS"])

        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:user_channel, user: other_user, channel: channel, modes: [])

        message = %Message{command: "TAGMSG", params: [channel.name], tags: %{"example" => "1"}}

        assert :ok = Tagmsg.handle(user, message)

        assert_sent_messages([
          {other_user.pid,
           "@example=1 :#{user.nick}!#{String.slice(user.ident, 0..9)}@#{user.hostname} TAGMSG #staff\r\n"}
        ])
      end)
    end

    test "returns error when sending TAGMSG to a user that does not exist" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["MESSAGE-TAGS"])
        message = %Message{command: "TAGMSG", params: ["UnknownNick"]}

        assert :ok = Tagmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 401 #{user.nick} UnknownNick :No such nick\r\n"}
        ])
      end)
    end

    test "returns error when sending TAGMSG to an unknown channel" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["MESSAGE-TAGS"])
        channel_name = "#unknown"
        message = %Message{command: "TAGMSG", params: [channel_name]}

        assert :ok = Tagmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 403 #{user.nick} #{channel_name} :No such channel\r\n"}
        ])
      end)
    end

    test "returns error when sending TAGMSG to a moderated or no-outside-messages channel the user is not in" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["MESSAGE-TAGS"])
        channel = insert(:channel, name: "#mod", modes: ["m"])
        message = %Message{command: "TAGMSG", params: [channel.name]}

        assert :ok = Tagmsg.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 404 #{user.nick} #{channel.name} :Cannot send to channel\r\n"}
        ])
      end)
    end

    test "returns delay error when channel has +d and user has not waited enough" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["MESSAGE-TAGS"])
        channel = insert(:channel, name: "#delay", modes: [{"d", "10"}])

        insert(:user_channel, user: user, channel: channel, created_at: DateTime.utc_now(), modes: [])

        message = %Message{command: "TAGMSG", params: [channel.name]}

        assert :ok = Tagmsg.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 937 #{user.nick} #{channel.name} :You must wait 10 seconds after joining before speaking in this channel.\r\n"}
        ])
      end)
    end

    test "returns error when sending TAGMSG to a restricted user without +r" do
      Memento.transaction!(fn ->
        sender = insert(:user, capabilities: ["MESSAGE-TAGS"], modes: [])
        recipient = insert(:user, modes: ["R"])

        message = %Message{command: "TAGMSG", params: [recipient.nick]}

        assert :ok = Tagmsg.handle(sender, message)

        assert_sent_messages([
          {sender.pid,
           ":irc.test 477 #{sender.nick} #{recipient.nick} :You must be identified to message this user\r\n"}
        ])
      end)
    end

    test "silences TAGMSG when recipient has a matching silence mask" do
      Memento.transaction!(fn ->
        recipient = insert(:user)
        sender = insert(:user, capabilities: ["MESSAGE-TAGS"], nick: "spammer", ident: "spam", hostname: "evil.com")

        insert(:user_silence, user: recipient, mask: "spammer!spam@evil.com")

        message = %Message{command: "TAGMSG", params: [recipient.nick], tags: %{"example" => "1"}}

        assert :ok = Tagmsg.handle(sender, message)

        # Nenhuma mensagem é enviada ao destinatário silenciado.
        assert_sent_messages([])
      end)
    end
  end
end
