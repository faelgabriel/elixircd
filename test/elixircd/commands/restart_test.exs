defmodule ElixIRCd.Commands.RestartTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]
  import Mimic

  alias ElixIRCd.Commands.Restart
  alias ElixIRCd.Message

  describe "handle/2" do
    setup :set_mimic_global

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

        Application
        |> expect(:stop, 1, fn :elixircd -> :ok end)
        |> expect(:start, 1, fn :elixircd -> :ok end)

        assert :ok = Restart.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com NOTICE * :Server is restarting\r\n"},
          {user.pid, ":server.example.com ERROR :Closing Link: #{user_mask(user)} (Server is restarting)\r\n"}
        ])

        # waits for the server to restart
        Process.sleep(125)

        verify!()
      end)
    end

    test "handles RESTART command with user operator and reason" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        message = %Message{command: "RESTART", params: ["#reason"], trailing: "Restarting reason"}

        Application
        |> expect(:stop, 1, fn :elixircd -> :ok end)
        |> expect(:start, 1, fn :elixircd -> :ok end)

        assert :ok = Restart.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com NOTICE * :Server is restarting: Restarting reason\r\n"},
          {user.pid,
           ":server.example.com ERROR :Closing Link: #{user_mask(user)} (Server is restarting: Restarting reason)\r\n"}
        ])

        # waits for the server to restart
        Process.sleep(125)

        verify!()
      end)
    end
  end
end
