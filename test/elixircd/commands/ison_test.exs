defmodule ElixIRCd.Commands.IsonTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Ison
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles ISON command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "ISON", params: ["#anything"]}

        assert :ok = Ison.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles ISON command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "ISON", params: []}

        assert :ok = Ison.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} ISON :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles ISON command" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "nick1")
        insert(:user, nick: "nick2")
        insert(:user, nick: "nick3")

        message = %Message{command: "ISON", params: ["nick1", "nick2", "invalid_nick", "nick3"]}
        assert :ok = Ison.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 303 #{user.nick} :nick1 nick2 nick3\r\n"}
        ])
      end)
    end
  end
end
