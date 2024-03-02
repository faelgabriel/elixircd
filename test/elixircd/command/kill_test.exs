defmodule ElixIRCd.Command.KillTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Kill
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles KILL command with user not registered" do
      Memento.transaction(fn ->
        user = insert(:user, identity: nil)
        message = %Message{command: "KILL", params: ["#anything"]}

        Kill.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end
  end
end
