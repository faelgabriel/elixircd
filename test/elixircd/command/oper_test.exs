defmodule ElixIRCd.Command.OperTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Oper
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles OPER command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, identity: nil)
        message = %Message{command: "OPER", params: ["#anything"]}

        Oper.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles OPER command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "OPER", params: []}
        Oper.handle(user, message)

        message = %Message{command: "OPER", params: ["only_username"]}
        Oper.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} OPER :Not enough parameters\r\n"},
          {user.socket, ":server.example.com 461 #{user.nick} OPER :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles OPER command" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "OPER", params: ["username", "password"]}
        Oper.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
