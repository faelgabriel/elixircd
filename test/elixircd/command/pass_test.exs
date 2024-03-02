defmodule ElixIRCd.Command.PassTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  alias ElixIRCd.Command.Pass
  alias ElixIRCd.Message

  import ElixIRCd.Factory

  describe "handle/2" do
    test "handles PASS command with user registered" do
      Memento.transaction!(fn ->
        user = insert(:user, identity: "identity")
        message = %Message{command: "PASS", params: ["password"]}

        Pass.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 462 #{user.nick} :Unauthorized command (already registered)\r\n"}
        ])
      end)
    end

    test "handles PASS command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user, identity: nil)
        message = %Message{command: "PASS", params: []}

        Pass.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 * PASS :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles PASS command with valid password" do
      Memento.transaction!(fn ->
        user = insert(:user, identity: nil)
        message = %Message{command: "PASS", params: ["password"]}

        Pass.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
