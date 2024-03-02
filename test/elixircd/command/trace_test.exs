defmodule ElixIRCd.Command.TraceTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Trace
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles TRACE command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, identity: nil)
        message = %Message{command: "TRACE", params: ["#anything"]}

        Trace.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles TRACE command with target parameter" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "TRACE", params: ["target"]}

        Trace.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles TRACE command without target parameter" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "TRACE", params: []}

        Trace.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
