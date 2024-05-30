defmodule ElixIRCd.Command.DieTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Helper, only: [build_user_mask: 1]
  import Mimic

  alias ElixIRCd.Command.Die
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles DIE command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "DIE", params: ["#anything"]}

        Die.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles DIE command with user not operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "DIE", params: []}

        Die.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 481 #{user.nick} :Permission Denied- You're not an IRC operator\r\n"}
        ])
      end)
    end

    test "handles DIE command with user operator" do
      Memento.transaction!(fn ->
        System
        |> expect(:halt, 1, fn 0 -> :ok end)

        user = insert(:user, modes: ["o"])
        message = %Message{command: "DIE", params: []}

        Die.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com NOTICE * :Server is shutting down\r\n"},
          {user.socket,
           ":server.example.com ERROR :Closing Link: #{build_user_mask(user)} (Server is shutting down)\r\n"}
        ])
      end)
    end

    test "handles DIE command with user operator and reason" do
      Memento.transaction!(fn ->
        System
        |> expect(:halt, 1, fn 0 -> :ok end)

        user = insert(:user, modes: ["o"])
        message = %Message{command: "DIE", params: ["#reason"], trailing: "Shutting down reason"}

        Die.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com NOTICE * :Server is shutting down: Shutting down reason\r\n"},
          {user.socket,
           ":server.example.com ERROR :Closing Link: #{build_user_mask(user)} (Server is shutting down: Shutting down reason)\r\n"}
        ])
      end)
    end
  end
end
