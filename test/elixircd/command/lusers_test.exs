defmodule ElixIRCd.Command.LusersTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Lusers
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles LUSERS command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "LUSERS", params: ["#anything"]}

        assert :ok = Lusers.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles LUSERS command" do
      Memento.transaction!(fn ->
        insert(:user, registered: true, modes: [])
        insert(:user, registered: true, modes: ["i"])
        insert(:user, registered: true, modes: ["o"])
        insert(:user, registered: false)

        user = insert(:user)
        message = %Message{command: "LUSERS", params: []}

        assert :ok = Lusers.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 251 #{user.nick} :There are 3 users and 1 invisible on 1 server\r\n"},
          {user.socket, ":server.example.com 252 #{user.nick} 1 :operator(s) online\r\n"},
          {user.socket, ":server.example.com 253 #{user.nick} 1 :unknown connection(s)\r\n"},
          {user.socket, ":server.example.com 254 #{user.nick} 0 :channels formed\r\n"},
          {user.socket, ":server.example.com 255 #{user.nick} :I have 5 clients and 0 servers\r\n"},
          {user.socket, ":server.example.com 265 #{user.nick} 5 1000 :Current local users 5, max 1000\r\n"},
          {user.socket, ":server.example.com 266 #{user.nick} 5 1000 :Current global users 5, max 1000\r\n"}
        ])
      end)
    end
  end
end
