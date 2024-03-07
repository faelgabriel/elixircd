defmodule ElixIRCd.Command.DieTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Die
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles DIE command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "DIE", params: ["#anything"]}

        Die.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles DIE command" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "DIE", params: []}

        Die.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
