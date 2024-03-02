defmodule ElixIRCd.Command.MotdTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Motd
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles MOTD command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, identity: nil)
        message = %Message{command: "MOTD", params: ["#anything"]}

        Motd.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles MOTD command" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "MOTD", params: []}

        Motd.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
