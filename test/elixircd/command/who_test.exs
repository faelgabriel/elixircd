defmodule ElixIRCd.Command.WhoTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Who
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles WHO command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "WHO", params: ["#anything"]}

        Who.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles WHO command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHO", params: []}

        Who.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} WHO :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles WHO command with target" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHO", params: ["target"]}

        Who.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
