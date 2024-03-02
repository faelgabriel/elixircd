defmodule ElixIRCd.Command.KickTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Kick
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles KICK command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, identity: nil)
        message = %Message{command: "KICK", params: ["#anything"]}

        Kick.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles KICK command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "KICK", params: []}
        Kick.handle(user, message)

        message = %Message{command: "KICK", params: ["#only_channel_name"]}
        Kick.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} KICK :Not enough parameters\r\n"},
          {user.socket, ":server.example.com 461 #{user.nick} KICK :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles KICK command" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)

        message = %Message{command: "KICK", params: [channel.name, user.nick], trailing: "reason"}

        Kick.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
