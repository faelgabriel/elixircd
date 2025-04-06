defmodule ElixIRCd.Commands.RehashTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Rehash
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles REHASH command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "REHASH", params: ["#anything"]}

        assert :ok = Rehash.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles REHASH command with user not operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "REHASH", params: []}

        assert :ok = Rehash.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 481 #{user.nick} :Permission Denied- You're not an IRC operator\r\n"}
        ])
      end)
    end

    test "handles REHASH command with user operator" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        message = %Message{command: "REHASH", params: []}

        assert :ok = Rehash.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 382 #{user.nick} runtime.exs :Rehashing\r\n"},
          {user.pid, ":irc.test NOTICE #{user.nick} :Rehashing completed\r\n"}
        ])
      end)
    end
  end
end
