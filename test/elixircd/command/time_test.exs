defmodule ElixIRCd.Command.TimeTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Time
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles TIME command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, identity: nil)
        message = %Message{command: "TIME", params: ["#anything"]}

        Time.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles TIME command" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "TIME", params: []}

        Time.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
