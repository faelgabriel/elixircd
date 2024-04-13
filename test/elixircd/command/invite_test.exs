defmodule ElixIRCd.Command.InviteTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Helper, only: [build_user_mask: 1]

  alias ElixIRCd.Repository.ChannelInvites
  alias ElixIRCd.Command.Invite
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles INVITE command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "INVITE", params: ["#anything"]}

        Invite.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles INVITE command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "INVITE", params: []}
        Invite.handle(user, message)

        message = %Message{command: "INVITE", params: ["#only_channel_name"]}
        Invite.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} INVITE :Not enough parameters\r\n"},
          {user.socket, ":server.example.com 461 #{user.nick} INVITE :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles INVITE command with target user not found" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "INVITE", params: ["target", "#channel"]}
        Invite.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 401 #{user.nick} target :No such nick/channel\r\n"}
        ])
      end)
    end

    test "handles INVITE command with channel not found" do
      Memento.transaction!(fn ->
        user = insert(:user)
        insert(:user, nick: "target")

        message = %Message{command: "INVITE", params: ["target", "#nonexistent"]}
        Invite.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 403 #{user.nick} #nonexistent :No such channel\r\n"}
        ])
      end)
    end

    test "handles INVITE command with user not in channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        insert(:user, nick: "target")
        insert(:channel, name: "#channel")

        message = %Message{command: "INVITE", params: ["target", "#channel"]}
        Invite.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 442 #{user.nick} #channel :You're not on that channel\r\n"}
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
        Invite.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 482 #{user.nick} #channel :You're not channel operator\r\n"}
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
        Invite.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 443 #{user.nick} target #channel :is already on channel\r\n"}
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
        Invite.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 341 #{user.nick} #{target_user.nick} #channel\r\n"},
          {target_user.socket, ":#{build_user_mask(user)} INVITE #{target_user.nick} #channel\r\n"}
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
        Invite.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 341 #{user.nick} #{target_user.nick} #channel\r\n"},
          {target_user.socket, ":#{build_user_mask(user)} INVITE #{target_user.nick} #channel\r\n"}
        ])

        assert ChannelInvites.get_by_user_port_and_channel_name(target_user.port, channel.name) != nil
      end)
    end
  end
end
