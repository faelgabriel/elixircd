defmodule ElixIRCd.Commands.DieTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Die
  alias ElixIRCd.Message

  describe "handle/2" do
    setup :set_mimic_global

    test "handles DIE command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "DIE", params: ["#anything"]}

        assert :ok = Die.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles DIE command with user not operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "DIE", params: []}

        assert :ok = Die.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 481 #{user.nick} :Permission Denied- You're not an IRC operator\r\n"}
        ])
      end)
    end

    test "handles DIE command with user operator" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        message = %Message{command: "DIE", params: []}

        System
        |> expect(:halt, 1, fn 0 -> :ok end)

        assert :ok = Die.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test NOTICE * :Server is shutting down\r\n"},
          {user.pid, ":irc.test ERROR :Closing Link: #{user_mask(user)} (Server is shutting down)\r\n"}
        ])

        # waits for the server to shutdown
        Process.sleep(125)

        verify!()
      end)
    end

    test "handles DIE command with user operator and reason" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        message = %Message{command: "DIE", params: ["#reason"], trailing: "Shutting down reason"}

        System
        |> expect(:halt, 1, fn 0 -> :ok end)

        assert :ok = Die.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test NOTICE * :Server is shutting down: Shutting down reason\r\n"},
          {user.pid,
           ":irc.test ERROR :Closing Link: #{user_mask(user)} (Server is shutting down: Shutting down reason)\r\n"}
        ])

        # waits for the server to shutdown
        Process.sleep(125)

        verify!()
      end)
    end
  end
end
