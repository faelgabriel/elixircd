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

    test "accepts the local server name and rejects remote targets" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Info.handle(user, %Message{command: "INFO", params: ["IRC.TEST"]})
        assert_sent_messages_amount(user.pid, 24)
        Agent.update(@agent_name, fn _ -> [] end)

        assert :ok = Info.handle(user, %Message{command: "INFO", params: ["remote.test"]})
        assert_sent_messages([{user.pid, ":irc.test 402 #{user.nick} remote.test :No such server\r\n"}])
      end)
    end
  end
end
