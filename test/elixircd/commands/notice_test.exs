defmodule ElixIRCd.Commands.NoticeTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Notice
  alias ElixIRCd.Message
  alias ElixIRCd.Service

  describe "handle/2" do
    test "handles NOTICE command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "NOTICE", params: ["#anything"]}

        assert :ok = Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles NOTICE command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "NOTICE", params: []}
        assert :ok = Notice.handle(user, message)

        message = %Message{command: "NOTICE", params: ["test"], trailing: nil}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles NOTICE command for channel with non-existing channel" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "NOTICE", params: ["#new_channel"], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles NOTICE command for channel with +n mode and user is not in the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [:n])

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles NOTICE command for channel without +n mode and user is not in the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "handles NOTICE command for channel with existing channel and user is in the channel with another user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel)
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "handles NOTICE command for user with non-existing user" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "NOTICE", params: ["another_user"], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles NOTICE command for user with existing user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)

        message = %Message{command: "NOTICE", params: [another_user.nick], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{another_user.nick} :Hello\r\n"}
        ])
      end)
    end

    test "echoes NOTICE commands back to the sender when ECHO-MESSAGE is enabled" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["echo-message"])
        another_user = insert(:user)

        message = %Message{command: "NOTICE", params: [another_user.nick], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{another_user.nick} :Hello\r\n"},
          {user.pid, ":#{user_mask(user)} NOTICE #{another_user.nick} :Hello\r\n"}
        ])
      end)
    end

    test "forwards only client-only tags on NOTICE to other message-tags clients and echo" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["message-tags", "echo-message"])
        another_user = insert(:user, capabilities: ["message-tags"])

        message =
          %Message{
            command: "NOTICE",
            params: [another_user.nick],
            trailing: "Hello",
            tags: %{"unknown-tag" => "abc", "+draft/reply" => "123"}
          }

        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid,
           Regex.compile!(
             "^@msgid=[A-Za-z0-9_-]{24};" <>
               Regex.escape("+draft/reply=123 :#{user_mask(user)} NOTICE #{another_user.nick} :Hello\r\n") <> "$"
           )},
          {user.pid,
           Regex.compile!(
             "^@msgid=[A-Za-z0-9_-]{24};" <>
               Regex.escape("+draft/reply=123 :#{user_mask(user)} NOTICE #{another_user.nick} :Hello\r\n") <> "$"
           )}
        ])
      end)
    end

    test "forwards only client-only tags on channel NOTICE to message-tags clients and echo" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["message-tags", "echo-message"])
        another_user = insert(:user, capabilities: ["message-tags"])
        channel = insert(:channel)

        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message =
          %Message{
            command: "NOTICE",
            params: [channel.name],
            trailing: "Hello",
            tags: %{"unknown-tag" => "abc", "+draft/reply" => "123"}
          }

        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid,
           Regex.compile!(
             "^@msgid=[A-Za-z0-9_-]{24};" <>
               Regex.escape("+draft/reply=123 :#{user_mask(user)} NOTICE #{channel.name} :Hello\r\n") <> "$"
           )},
          {user.pid,
           Regex.compile!(
             "^@msgid=[A-Za-z0-9_-]{24};" <>
               Regex.escape("+draft/reply=123 :#{user_mask(user)} NOTICE #{channel.name} :Hello\r\n") <> "$"
           )}
        ])
      end)
    end

    test "handles NOTICE command directed to a service with trailing message" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "NOTICE", params: ["NICKSERV"], trailing: "REGISTER password email@example.com"}

        expect(Service, :service_implemented?, fn "NICKSERV" -> true end)
        reject(Service, :dispatch, 3)

        assert :ok = Notice.handle(user, message)

        verify!()
      end)
    end

    test "handles NOTICE command directed to a service with params instead of trailing" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "NOTICE", params: ["NICKSERV", "IDENTIFY", "password"]}

        expect(Service, :service_implemented?, fn "NICKSERV" -> true end)
        reject(Service, :dispatch, 3)

        assert :ok = Notice.handle(user, message)

        verify!()
      end)
    end

    test "handles NOTICE command with case-insensitive service name" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "NOTICE", params: ["nickserv"], trailing: "REGISTER password email@example.com"}

        expect(Service, :service_implemented?, fn "nickserv" -> true end)
        reject(Service, :dispatch, 3)

        assert :ok = Notice.handle(user, message)

        verify!()
      end)
    end

    test "handles NOTICE command for user with +g mode and sender is not registered (silently ignored)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user, modes: [:g])

        message = %Message{command: "NOTICE", params: [another_user.nick], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles NOTICE command for user with +R mode and sender is not registered (silently ignored)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "TargetUser", modes: [:R])
        message = %Message{command: "NOTICE", params: [target_user.nick], trailing: "Hello"}

        Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles NOTICE command for user with +R mode and sender is registered (target gets message)" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: [:r])
        target_user = insert(:user, nick: "TargetUser", modes: [:R])
        message = %Message{command: "NOTICE", params: [target_user.nick], trailing: "Hello"}

        Notice.handle(user, message)

        assert_sent_messages([
          {target_user.pid, ":#{user_mask(user)} NOTICE #{target_user.nick} :Hello\r\n"}
        ])
      end)
    end

    test "blocks messages with color codes when +c mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:c])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "\x03Hello world"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "blocks messages with bold formatting when +c mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:c])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "\x02Bold text\x02"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "blocks messages with underline formatting when +c mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:c])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "\x1FUnderlined text\x1F"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "blocks messages with multiple formatting codes when +c mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:c])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "\x02\x03Bold and colored\x0F"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "allows plain text messages when +c mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:c])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello everyone!"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :Hello everyone!\r\n"}
        ])
      end)
    end

    test "allows formatted messages when +c mode is not set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "\x02Bold text\x02"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :\x02Bold text\x02\r\n"}
        ])
      end)
    end

    test "blocks messages when +d mode is set and user just joined" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [{:d, "5"}])
        insert(:user_channel, user: user, channel: channel, created_at: DateTime.utc_now())
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "allows messages when +d mode is set and enough time has passed" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [{:d, "5"}])
        past_time = DateTime.add(DateTime.utc_now(), -10, :second)
        insert(:user_channel, user: user, channel: channel, created_at: past_time)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "allows messages when +d mode is set and user is channel operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [{:d, "5"}])
        insert(:user_channel, user: user, channel: channel, modes: [:o], created_at: DateTime.utc_now())
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "allows messages when +d mode is set and user has voice" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [{:d, "5"}])
        insert(:user_channel, user: user, channel: channel, modes: [:v], created_at: DateTime.utc_now())
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "allows messages when +d mode is not set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, created_at: DateTime.utc_now())
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "silences user messages when user is in receiver's silence list" do
      Memento.transaction!(fn ->
        sender = insert(:user)
        receiver = insert(:user)
        insert(:user_silence, user: receiver, mask: "#{sender.nick}!*@*")

        message = %Message{command: "NOTICE", params: [receiver.nick], trailing: "Hello"}
        assert :ok = Notice.handle(sender, message)

        assert_sent_messages([])
      end)
    end

    test "blocks NOTICE messages for users not in channel when +T mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:T])
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "blocks NOTICE messages for regular users when +T mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:T])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "allows NOTICE messages for channel operators when +T mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:T])
        insert(:user_channel, user: user, channel: channel, modes: [:o])
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "allows NOTICE messages for users with voice when +T mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:T])
        insert(:user_channel, user: user, channel: channel, modes: [:v])
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "allows NOTICE messages when +T mode is not set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "handles NOTICE command with +M mode blocking unregistered users" do
      Memento.transaction!(fn ->
        unregistered_user = insert(:user, modes: [])
        another_user = insert(:user)
        channel = insert(:channel, modes: [:M])
        insert(:user_channel, user: unregistered_user, channel: channel, modes: [])
        insert(:user_channel, user: another_user, channel: channel, modes: [])

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(unregistered_user, message)

        assert_sent_messages([])
      end)
    end

    test "handles NOTICE command with +M mode allowing registered users" do
      Memento.transaction!(fn ->
        registered_user = insert(:user, modes: [:r])
        another_user = insert(:user)
        channel = insert(:channel, modes: [:M])
        insert(:user_channel, user: registered_user, channel: channel, modes: [])
        insert(:user_channel, user: another_user, channel: channel, modes: [])

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(registered_user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(registered_user)} NOTICE #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "handles NOTICE command with +M mode allowing operators even if not registered" do
      Memento.transaction!(fn ->
        unregistered_op = insert(:user, modes: [])
        another_user = insert(:user)
        channel = insert(:channel, modes: [:M])
        insert(:user_channel, user: unregistered_op, channel: channel, modes: [:o])
        insert(:user_channel, user: another_user, channel: channel, modes: [])

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(unregistered_op, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(unregistered_op)} NOTICE #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "handles NOTICE command with +M mode allowing voiced users even if not registered" do
      Memento.transaction!(fn ->
        unregistered_voiced = insert(:user, modes: [])
        another_user = insert(:user)
        channel = insert(:channel, modes: [:M])
        insert(:user_channel, user: unregistered_voiced, channel: channel, modes: [:v])
        insert(:user_channel, user: another_user, channel: channel, modes: [])

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(unregistered_voiced, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(unregistered_voiced)} NOTICE #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "handles NOTICE command for channel with +m mode and user is not voice or higher" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [:m])
        insert(:user_channel, user: user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles NOTICE command for channel with +m mode and user is voice" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:m])
        insert(:user_channel, user: user, channel: channel, modes: [:v])
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "handles NOTICE command for channel with +m mode and user is operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:m])
        insert(:user_channel, user: user, channel: channel, modes: [:o])
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "handles NOTICE command for channel with +n mode and user is in the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:n])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "Hello"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :Hello\r\n"}
        ])
      end)
    end

    test "blocks CTCP messages for users not in channel when +C mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:C])
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "\x01VERSION\x01"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "blocks CTCP messages for regular users when +C mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:C])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "\x01VERSION\x01"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "blocks VERSION CTCP messages for regular users when +C mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:C])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "\x01VERSION\x01"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "allows CTCP messages for channel operators when +C mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:C])
        insert(:user_channel, user: user, channel: channel, modes: [:o])
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "\x01ACTION waves\x01"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :\x01ACTION waves\x01\r\n"}
        ])
      end)
    end

    test "allows CTCP messages for voice users when +C mode is set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:C])
        insert(:user_channel, user: user, channel: channel, modes: [:v])
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "\x01ACTION dances\x01"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :\x01ACTION dances\x01\r\n"}
        ])
      end)
    end

    test "allows CTCP messages when +C mode is not set" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "\x01ACTION waves\x01"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :\x01ACTION waves\x01\r\n"}
        ])
      end)
    end

    test "handles malformed CTCP messages correctly" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)
        channel = insert(:channel, modes: [:C])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NOTICE", params: [channel.name], trailing: "\x01This is not a CTCP"}
        assert :ok = Notice.handle(user, message)

        assert_sent_messages([
          {another_user.pid, ":#{user_mask(user)} NOTICE #{channel.name} :\x01This is not a CTCP\r\n"}
        ])
      end)
    end

    test "delivers NOTICE to each advertised comma-separated target" do
      Memento.transaction!(fn ->
        sender = insert(:user)
        first = insert(:user, nick: "first")
        second = insert(:user, nick: "second")

        assert :ok =
                 Notice.handle(sender, %Message{
                   command: "NOTICE",
                   params: ["#{first.nick},#{second.nick}"],
                   trailing: "hello"
                 })

        assert_sent_messages([
          {first.pid, ":#{user_mask(sender)} NOTICE #{first.nick} :hello\r\n"},
          {second.pid, ":#{user_mask(sender)} NOTICE #{second.nick} :hello\r\n"}
        ])
      end)
    end

    test "delivers STATUSMSG NOTICE only to channel operators" do
      Memento.transaction!(fn ->
        sender = insert(:user)
        operator = insert(:user)
        regular = insert(:user)
        channel = insert(:channel)
        insert(:user_channel, user: sender, channel: channel)
        insert(:user_channel, user: operator, channel: channel, modes: [:o])
        insert(:user_channel, user: regular, channel: channel)

        assert :ok =
                 Notice.handle(sender, %Message{
                   command: "NOTICE",
                   params: ["@#{channel.name}"],
                   trailing: "ops"
                 })

        assert_sent_messages([
          {operator.pid, ":#{user_mask(sender)} NOTICE @#{channel.name} :ops\r\n"}
        ])
      end)
    end
  end
end
