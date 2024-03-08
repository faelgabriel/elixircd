defmodule ElixIRCd.Command.InviteTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

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

    test "handles INVITE command" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)

        message = %Message{command: "INVITE", params: [user.nick, channel.name]}
        Invite.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
