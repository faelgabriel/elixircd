defmodule ElixIRCd.Commands.OperTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Oper
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles OPER command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "OPER", params: ["#anything"]}

        assert :ok = Oper.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
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
          {user.pid, ":irc.test 461 #{user.nick} OPER :Not enough parameters\r\n"},
          {user.pid, ":irc.test 461 #{user.nick} OPER :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles OPER command with valid credentials" do
      # Argon2id hashing
      # User: admin / Password: admin
      operators = [
        %{
          nick: "admin",
          password: "$argon2id$v=19$m=4096,t=2,p=4$0Ikum7IgbC2CkId/UJQE7A$n1YVbtPj1nP4EfdL771tPCS1PmK+Q364g14ScJzBaSg",
          hostmasks: ["*@*"],
          type: "admin",
          vhost: nil
        }
      ]

      original_config = Application.get_env(:elixircd, :operators)
      Application.put_env(:elixircd, :operators, operators)
      on_exit(fn -> Application.put_env(:elixircd, :operators, original_config) end)

      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "OPER", params: ["admin", "admin"]}
        assert :ok = Oper.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 381 #{user.nick} :You are now an IRC operator\r\n"}
        ])
      end)
    end

    test "handles OPER command with invalid credentials" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "OPER", params: ["admin", "invalid"]}
        assert :ok = Oper.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 464 #{user.nick} :Password incorrect\r\n"}
        ])
      end)
    end
  end
end
