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
        user = insert(:user, identity: nil)
        message = %Message{command: "ADMIN", params: ["#anything"]}

        Admin.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles ADMIN command with server parameter" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "ADMIN", params: ["server.example.com"]}

        Admin.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles ADMIN command without server parameter" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "ADMIN", params: []}

        Admin.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
