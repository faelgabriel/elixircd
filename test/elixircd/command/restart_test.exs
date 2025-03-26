defmodule ElixIRCd.Command.RestartTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Helper, only: [get_user_mask: 1]

  alias ElixIRCd.Command.Restart
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles RESTART command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "RESTART", params: ["#anything"]}

        assert :ok = Restart.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles RESTART command with user not operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "RESTART", params: []}

        assert :ok = Restart.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 481 #{user.nick} :Permission Denied- You're not an IRC operator\r\n"}
        ])
      end)
    end

    test "handles RESTART command with user operator" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        message = %Message{command: "RESTART", params: []}

        assert :ok = Restart.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com NOTICE * :Server is restarting\r\n"},
          {user.pid, ":server.example.com ERROR :Closing Link: #{get_user_mask(user)} (Server is restarting)\r\n"}
        ])
      end)
    end

    test "handles RESTART command with user operator and reason" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        message = %Message{command: "RESTART", params: ["#reason"], trailing: "Restarting reason"}

        assert :ok = Restart.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com NOTICE * :Server is restarting: Restarting reason\r\n"},
          {user.pid,
           ":server.example.com ERROR :Closing Link: #{get_user_mask(user)} (Server is restarting: Restarting reason)\r\n"}
        ])
      end)
    end
  end
end
