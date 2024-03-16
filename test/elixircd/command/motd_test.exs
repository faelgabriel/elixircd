defmodule ElixIRCd.Command.MotdTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Motd
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles MOTD command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "MOTD", params: ["#anything"]}

        Motd.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles MOTD command" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "MOTD", params: []}

        Motd.handle(user, message)

        assert_sent_messages([
          {user.socket,
           ":server.example.com 001 #{user.nick} :Welcome to the Server Example Internet Relay Chat Network #{user.nick}\r\n"},
          {user.socket,
           ":server.example.com 002 #{user.nick} :Your host is Server Example, running version 0.1.0.\r\n"},
          {user.socket, ":server.example.com 003 #{user.nick} :This server was created ...\r\n"},
          {user.socket, ":server.example.com 004 #{user.nick} :ElixIRCd 0.1.0 +i +int\r\n"},
          {user.socket, ":server.example.com 376 #{user.nick} :End of MOTD command\r\n"}
        ])
      end)
    end
  end
end
