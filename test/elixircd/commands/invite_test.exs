defmodule ElixIRCd.Commands.InviteTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Invite
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelInvites

  describe "handle/2" do
    for account_enabled <- [true, false], identified_as <- [nil, "inviter-account"] do
      test "INVITE account tags enabled=#{account_enabled} account=#{inspect(identified_as)} are filtered per recipient" do
        original_config = Application.get_env(:elixircd, :capabilities)
        on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

        Application.put_env(
          :elixircd,
          :capabilities,
          Keyword.put(original_config, :account_tag, unquote(account_enabled))
        )

        Memento.transaction!(fn ->
          inviter = insert(:user, identified_as: unquote(identified_as))
          invitee = insert(:user, identified_as: "invitee-account", capabilities: ["account-tag"])
          tagged_member = insert(:user, capabilities: ["invite-notify", "account-tag"])
          plain_member = insert(:user, capabilities: ["invite-notify", "message-tags"])
          silent_member = insert(:user, capabilities: ["account-tag"])
          outsider = insert(:user, capabilities: ["invite-notify", "account-tag"])
          channel = insert(:channel)
          insert(:user_channel, user: inviter, channel: channel, modes: ["o"])

          for member <- [tagged_member, plain_member, silent_member] do
            insert(:user_channel, user: member, channel: channel)
          end

          assert :ok = Invite.handle(inviter, %Message{command: "INVITE", params: [invitee.nick, channel.name]})
          tag = if unquote(account_enabled) and unquote(identified_as) != nil, do: "@account=inviter-account ", else: ""
          invite = ":#{user_mask(inviter)} INVITE #{invitee.nick} #{channel.name}\r\n"

          assert_sent_messages_amount(silent_member.pid, 0)
          assert_sent_messages_amount(outsider.pid, 0)

          assert_sent_messages([
            {inviter.pid, ":irc.test 341 #{inviter.nick} #{invitee.nick} #{channel.name}\r\n"},
            {invitee.pid, tag <> invite},
            {tagged_member.pid, tag <> invite},
            {plain_member.pid, invite}
          ])
        end)
      end
    end

    test "handles INVITE command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "INVITE", params: ["#anything"]}

        assert :ok = Invite.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles INVITE command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "INVITE", params: []}
        assert :ok = Invite.handle(user, message)

        message = %Message{command: "INVITE", params: ["#only_channel_name"]}
        assert :ok = Invite.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} INVITE :Not enough parameters\r\n"},
          {user.pid, ":irc.test 461 #{user.nick} INVITE :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles INVITE command with target user not found" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "INVITE", params: ["target", "#channel"]}
        assert :ok = Invite.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 401 #{user.nick} target :No such nick/channel\r\n"}
        ])
      end)
    end

    test "handles INVITE command with channel not found" do
      Memento.transaction!(fn ->
        user = insert(:user)
        insert(:user, nick: "target")

        message = %Message{command: "INVITE", params: ["target", "#nonexistent"]}
        assert :ok = Invite.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 403 #{user.nick} #nonexistent :No such channel\r\n"}
        ])
      end)
    end

    test "handles INVITE command with user not in channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        insert(:user, nick: "target")
        insert(:channel, name: "#channel")

        message = %Message{command: "INVITE", params: ["target", "#channel"]}
        assert :ok = Invite.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 442 #{user.nick} #channel :You're not on that channel\r\n"}
        ])
      end)
    end

    test "handles INVITE command with user not operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#channel")
        insert(:user_channel, user: user, channel: channel)
        insert(:user, nick: "target")

        message = %Message{command: "INVITE", params: ["target", "#channel"]}
        assert :ok = Invite.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 482 #{user.nick} #channel :You're not channel operator\r\n"}
        ])
      end)
    end

    test "handles INVITE command with target user already on channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#channel")
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        user_target = insert(:user, nick: "target")
        insert(:user_channel, user: user_target, channel: channel)

        message = %Message{command: "INVITE", params: ["target", "#channel"]}
        assert :ok = Invite.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 443 #{user.nick} target #channel :is already on channel\r\n"}
        ])
      end)
    end

    test "handles INVITE command with success" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user)
        channel = insert(:channel, name: "#channel")
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "INVITE", params: [target_user.nick, "#channel"]}
        assert :ok = Invite.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 341 #{user.nick} #{target_user.nick} #channel\r\n"},
          {target_user.pid, ":#{user_mask(user)} INVITE #{target_user.nick} #channel\r\n"}
        ])
      end)
    end

    test "handles INVITE command with success when channel has +i mode" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user)
        channel = insert(:channel, name: "#channel", modes: ["i"])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "INVITE", params: [target_user.nick, "#channel"]}
        assert :ok = Invite.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 341 #{user.nick} #{target_user.nick} #channel\r\n"},
          {target_user.pid, ":#{user_mask(user)} INVITE #{target_user.nick} #channel\r\n"}
        ])

        assert {:ok, _channel_invite} = ChannelInvites.get_by_user_pid_and_channel_name(target_user.pid, channel.name)
      end)
    end

    test "handles INVITE command with success when target user is away" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, away_message: "I'm away")
        channel = insert(:channel, name: "#channel")
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "INVITE", params: [target_user.nick, "#channel"]}
        assert :ok = Invite.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 301 #{user.nick} #{target_user.nick} :I'm away\r\n"},
          {user.pid, ":irc.test 341 #{user.nick} #{target_user.nick} #channel\r\n"},
          {target_user.pid, ":#{user_mask(user)} INVITE #{target_user.nick} #channel\r\n"}
        ])
      end)
    end

    test "handles INVITE command with ACCOUNT-TAG capability and authenticated user" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "alice")
        target_user = insert(:user, capabilities: ["account-tag"])
        channel = insert(:channel, name: "#channel")
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "INVITE", params: [target_user.nick, "#channel"]}
        assert :ok = Invite.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 341 #{user.nick} #{target_user.nick} #channel\r\n"},
          {target_user.pid, "@account=alice :#{user_mask(user)} INVITE #{target_user.nick} #channel\r\n"}
        ])
      end)
    end

    test "handles INVITE command with ACCOUNT-TAG capability and unauthenticated user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, capabilities: ["account-tag"])
        channel = insert(:channel, name: "#channel")
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "INVITE", params: [target_user.nick, "#channel"]}
        assert :ok = Invite.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 341 #{user.nick} #{target_user.nick} #channel\r\n"},
          {target_user.pid, ":#{user_mask(user)} INVITE #{target_user.nick} #channel\r\n"}
        ])
      end)
    end

    test "handles INVITE command with INVITE-NOTIFY capability for channel members" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user)
        member_with_notify = insert(:user, capabilities: ["invite-notify"])
        member_without_notify = insert(:user)
        channel = insert(:channel, name: "#channel")
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:user_channel, user: member_with_notify, channel: channel)
        insert(:user_channel, user: member_without_notify, channel: channel)

        message = %Message{command: "INVITE", params: [target_user.nick, "#channel"]}
        assert :ok = Invite.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 341 #{user.nick} #{target_user.nick} #channel\r\n"},
          {target_user.pid, ":#{user_mask(user)} INVITE #{target_user.nick} #channel\r\n"},
          {member_with_notify.pid, ":#{user_mask(user)} INVITE #{target_user.nick} #channel\r\n"}
        ])
      end)
    end

    test "handles INVITE command without sending notification when no members have INVITE-NOTIFY" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user)
        member = insert(:user)
        channel = insert(:channel, name: "#channel")
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:user_channel, user: member, channel: channel)

        message = %Message{command: "INVITE", params: [target_user.nick, "#channel"]}
        assert :ok = Invite.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 341 #{user.nick} #{target_user.nick} #channel\r\n"},
          {target_user.pid, ":#{user_mask(user)} INVITE #{target_user.nick} #channel\r\n"}
        ])
      end)
    end

    test "handles INVITE command with both INVITE-NOTIFY and ACCOUNT-TAG capabilities" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "alice")
        target_user = insert(:user, capabilities: ["account-tag"])
        member = insert(:user, capabilities: ["invite-notify"])
        channel = insert(:channel, name: "#channel")
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:user_channel, user: member, channel: channel)

        message = %Message{command: "INVITE", params: [target_user.nick, "#channel"]}
        assert :ok = Invite.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 341 #{user.nick} #{target_user.nick} #channel\r\n"},
          {target_user.pid, "@account=alice :#{user_mask(user)} INVITE #{target_user.nick} #channel\r\n"},
          {member.pid, ":#{user_mask(user)} INVITE #{target_user.nick} #channel\r\n"}
        ])
      end)
    end
  end
end
