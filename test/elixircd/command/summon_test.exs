defmodule ElixIRCd.Command.SummonTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Summon
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles SUMMON command with user not registered" do
      Memento.transaction(fn ->
        user = insert(:user, identity: nil)
        message = %Message{command: "SUMMON", params: ["#anything"]}

        Summon.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end
  end
end
