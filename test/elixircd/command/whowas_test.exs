defmodule ElixIRCd.Command.WhowasTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Whowas
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles WHOWAS command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "WHOWAS", params: ["#anything"]}

        Whowas.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles WHOWAS command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHOWAS", params: []}

        Whowas.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} WHOWAS :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles WHOWAS command with target nick" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHOWAS", params: [user.nick]}

        Whowas.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles WHOWAS command with target nick and max replies" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHOWAS", params: [user.nick, "5"]}

        Whowas.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
