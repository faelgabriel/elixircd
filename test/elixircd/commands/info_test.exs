defmodule ElixIRCd.Commands.InfoTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Info
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles INFO command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "INFO", params: ["#anything"]}

        assert :ok = Info.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles INFO command" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "INFO", params: []}

        assert :ok = Info.handle(user, message)

        assert_sent_messages_amount(user.pid, 24)
      end)
    end
  end
end
