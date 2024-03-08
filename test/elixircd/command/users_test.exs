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

        Users.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles USERS command" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "USERS", params: []}

        Users.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
