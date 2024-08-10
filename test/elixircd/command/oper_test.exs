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
        user = insert(:user, registered: false)
        message = %Message{command: "OPER", params: ["#anything"]}

        assert :ok = Oper.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles OPER command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "OPER", params: []}
        assert :ok = Oper.handle(user, message)

        message = %Message{command: "OPER", params: ["only_username"]}
        assert :ok = Oper.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} OPER :Not enough parameters\r\n"},
          {user.socket, ":server.example.com 461 #{user.nick} OPER :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles OPER command with valid credentials" do
      # Argon2 hash is required for the password
      # User: admin / Password: admin
      operators = [
        {"admin", "$argon2id$v=19$m=65536,t=3,p=4$FDb7o+zPhX+AIfcPDZ7O+g$IBllcYuvYr6dSuAb+qEuB72/YWwTwaTVhmFX2XKp76Q"}
      ]

      original_config = Application.get_env(:elixircd, :operators)
      Application.put_env(:elixircd, :operators, operators)
      on_exit(fn -> Application.put_env(:elixircd, :operators, original_config) end)

      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "OPER", params: ["admin", "admin"]}
        assert :ok = Oper.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 381 #{user.nick} :You are now an IRC operator\r\n"}
        ])
      end)
    end

    test "handles OPER command with invalid credentials" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "OPER", params: ["admin", "invalid"]}
        assert :ok = Oper.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 464 #{user.nick} :Password incorrect\r\n"}
        ])
      end)
    end
  end
end
