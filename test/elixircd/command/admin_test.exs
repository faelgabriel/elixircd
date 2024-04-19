defmodule ElixIRCd.Command.AdminTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Admin
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles ADMIN command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "ADMIN", params: ["#anything"]}

        Admin.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles ADMIN command" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "ADMIN", params: []}

        Admin.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 256 #{user.nick} :Administrative info about Server Example\r\n"},
          {user.socket, ":server.example.com 257 #{user.nick} :Server Location Here\r\n"},
          {user.socket, ":server.example.com 258 #{user.nick} :Organization Name Here\r\n"},
          {user.socket, ":server.example.com 259 #{user.nick} :admin@example.com\r\n"}
        ])
      end)
    end
  end
end
