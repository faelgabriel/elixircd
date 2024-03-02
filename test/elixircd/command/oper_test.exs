defmodule ElixIRCd.Command.OperTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Oper
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles OPER command with user not registered" do
      Memento.transaction(fn ->
        user = insert(:user, identity: nil)
        message = %Message{command: "OPER", params: ["#anything"]}

        Oper.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end
  end
end
