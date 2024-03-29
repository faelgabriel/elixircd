defmodule ElixIRCd.Command.RestartTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Restart
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles RESTART command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "RESTART", params: ["#anything"]}

        Restart.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles RESTART command" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "RESTART", params: []}

        Restart.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
