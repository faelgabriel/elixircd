defmodule ElixIRCd.Commands.OperTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Oper
  alias ElixIRCd.Message
  alias ElixIRCd.Operators
  alias ElixIRCd.Repositories.Users

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
        {"admin", "$argon2id$v=19$m=4096,t=2,p=4$0Ikum7IgbC2CkId/UJQE7A$n1YVbtPj1nP4EfdL771tPCS1PmK+Q364g14ScJzBaSg"}
      ]

      original_config = Application.get_env(:elixircd, :operators)
      Application.put_env(:elixircd, :operators, operators)
      on_exit(fn -> Application.put_env(:elixircd, :operators, original_config) end)

      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "OPER", params: ["admin", "admin"]}
        assert :ok = Oper.handle(user, message)
        assert {:ok, active} = Users.get_by_pid(user.pid)
        assert active.oper_source == :config
        assert active.oper_name == "admin"

        assert_sent_messages([
          {user.pid, ":irc.test 381 #{user.nick} :You are now an IRC operator\r\n"},
          {user.pid, ":irc.test MODE #{user.nick} +o\r\n"}
        ])
      end)
    end

    test "records the database credential used by OPER" do
      hash = Argon2.hash_pwd_salt("a-long-password")
      assert :ok = Operators.Management.add("managed", hash)
      user = insert(:user)

      assert :ok =
               Memento.transaction!(fn ->
                 Oper.handle(user, %Message{command: "OPER", params: ["managed", "a-long-password"]})
               end)

      assert {:ok, active} = Memento.transaction!(fn -> Users.get_by_pid(user.pid) end)
      assert active.oper_source == :database
      assert active.oper_name == "managed"
      assert :o in active.modes
      assert_sent_message_contains(user.pid, ~r/You are now an IRC operator/)
      assert_sent_message_contains(user.pid, ~r/MODE .* \+o/)
    end

    test "uses the locked user state and ignores a user already removed from Mnesia" do
      original = Application.fetch_env!(:elixircd, :operators)
      Application.put_env(:elixircd, :operators, [{"admin", Argon2.hash_pwd_salt("a-long-password")}])
      on_exit(fn -> Application.put_env(:elixircd, :operators, original) end)

      user = insert(:user, modes: [:i])
      Memento.transaction!(fn -> Users.update(user, %{modes: [:i, :w]}) end)

      assert :ok =
               Memento.transaction!(fn ->
                 Oper.handle(user, %Message{command: "OPER", params: ["admin", "a-long-password"]})
               end)

      assert {:ok, active} = Memento.transaction!(fn -> Users.get_by_pid(user.pid) end)
      assert Enum.sort(active.modes) == [:i, :o, :w]

      removed = insert(:user)
      Memento.transaction!(fn -> Users.delete(removed) end)

      assert :ok =
               Memento.transaction!(fn ->
                 Oper.handle(removed, %Message{command: "OPER", params: ["admin", "a-long-password"]})
               end)

      assert {:error, :user_not_found} = Memento.transaction!(fn -> Users.get_by_pid(removed.pid) end)
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

    test "sends snotice to operators with +s mode when OPER succeeds" do
      operators = [
        {"admin", "$argon2id$v=19$m=4096,t=2,p=4$0Ikum7IgbC2CkId/UJQE7A$n1YVbtPj1nP4EfdL771tPCS1PmK+Q364g14ScJzBaSg"}
      ]

      original_config = Application.get_env(:elixircd, :operators)
      Application.put_env(:elixircd, :operators, operators)
      on_exit(fn -> Application.put_env(:elixircd, :operators, original_config) end)

      Memento.transaction!(fn ->
        user = insert(:user)
        oper_with_s = insert(:user, modes: [:o, :s])

        message = %Message{command: "OPER", params: ["admin", "admin"]}
        assert :ok = Oper.handle(user, message)

        user_info = "#{user.nick}!#{user.ident}@#{user.hostname} [127.0.0.1]"
        expected_snotice = ":irc.test NOTICE :*** Oper: #{user_info} opered as admin\r\n"

        assert_sent_messages([
          {user.pid, ":irc.test 381 #{user.nick} :You are now an IRC operator\r\n"},
          {user.pid, ":irc.test MODE #{user.nick} +o\r\n"},
          {oper_with_s.pid, expected_snotice}
        ])
      end)
    end

    test "sends snotice to operators with +s mode when OPER fails" do
      Memento.transaction!(fn ->
        user = insert(:user)
        oper_with_s = insert(:user, modes: [:o, :s])

        message = %Message{command: "OPER", params: ["admin", "wrongpass"]}
        assert :ok = Oper.handle(user, message)

        user_info = "#{user.nick}!#{user.ident}@#{user.hostname} [127.0.0.1]"
        expected_snotice = ":irc.test NOTICE :*** Oper: Failed OPER attempt by #{user_info} (username: admin)\r\n"

        assert_sent_messages([
          {user.pid, ":irc.test 464 #{user.nick} :Password incorrect\r\n"},
          {oper_with_s.pid, expected_snotice}
        ])
      end)
    end
  end
end
