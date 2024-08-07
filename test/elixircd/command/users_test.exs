defmodule ElixIRCd.Command.UsersTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Users
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles USERS command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "USERS", params: ["#anything"]}

        assert :ok = Users.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles USERS command" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "USERS", params: []}

        assert :ok = Users.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 265 #{user.nick} 1 1000 :Current local users 1, max 1000\r\n"},
          {user.socket, ":server.example.com 266 #{user.nick} 1 1000 :Current global users 1, max 1000\r\n"}
        ])
      end)
    end
  end
end
