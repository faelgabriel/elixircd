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

        Lusers.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles LUSERS command" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "LUSERS", params: []}

        Lusers.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
