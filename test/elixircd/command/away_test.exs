defmodule ElixIRCd.Command.AwayTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Away
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles AWAY command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, identity: nil)
        message = %Message{command: "AWAY", params: ["#anything"]}

        Away.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles AWAY command with no message" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "AWAY", params: []}

        Away.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles AWAY command with message" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "AWAY", params: [], trailing: "I'm away"}

        Away.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
