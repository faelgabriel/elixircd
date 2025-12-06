defmodule ElixIRCd.Commands.UserTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.User
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Handshake

  describe "handle/2" do
    test "handles USER command with not enough parameters for user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)

        message = %Message{command: "USER", params: []}
        assert :ok = User.handle(user, message)

        message = %Message{command: "USER", params: ["username"]}
        assert :ok = User.handle(user, message)

        message = %Message{command: "USER", params: ["username", "0"]}
        assert :ok = User.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 * USER :Not enough parameters\r\n"},
          {user.pid, ":irc.test 461 * USER :Not enough parameters\r\n"},
          {user.pid, ":irc.test 461 * USER :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles USER command with valid and invalid parameters for user registered" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "USER", params: [], trailing: nil}
        assert :ok = User.handle(user, message)

        message = %Message{command: "USER", params: ["username", "0", "*"], trailing: "real name"}
        assert :ok = User.handle(user, message)

        message = %Message{command: "USER", params: ["username", "0", "*", "realname"]}
        assert :ok = User.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 462 #{user.nick} :You may not reregister\r\n"},
          {user.pid, ":irc.test 462 #{user.nick} :You may not reregister\r\n"},
          {user.pid, ":irc.test 462 #{user.nick} :You may not reregister\r\n"}
        ])
      end)
    end

    test "handles USER command with valid parameters for user not registered" do
      Handshake
      |> expect(:handle, 2, fn _user -> :ok end)

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)

        message = %Message{command: "USER", params: ["username", "0", "*"], trailing: "real name"}
        assert :ok = User.handle(user, message)

        message = %Message{command: "USER", params: ["username", "0", "*", "realname"]}
        assert :ok = User.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles USER command with ident exceeding max length" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)

        long_username = "12345678901"
        message = %Message{command: "USER", params: [long_username, "0", "*"], trailing: "real name"}
        assert :ok = User.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 468 * :Your username is invalid (maximum 10 characters)\r\n"}
        ])
      end)
    end

    test "handles USER command with realname exceeding max length and truncates it" do
      Handshake
      |> expect(:handle, 1, fn updated_user ->
        assert String.length(updated_user.realname) == 50
        assert updated_user.realname == "12345678901234567890123456789012345678901234567890"
        :ok
      end)

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)

        long_realname = "123456789012345678901234567890123456789012345678901234567890"
        message = %Message{command: "USER", params: ["username", "0", "*"], trailing: long_realname}
        assert :ok = User.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "respects custom max_ident_length configuration" do
      original_user_config = Application.get_env(:elixircd, :user)
      on_exit(fn -> Application.put_env(:elixircd, :user, original_user_config) end)

      Application.put_env(
        :elixircd,
        :user,
        (original_user_config || [])
        |> Keyword.put(:max_ident_length, 5)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)

        username = "123456"
        message = %Message{command: "USER", params: [username, "0", "*"], trailing: "real name"}
        assert :ok = User.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 468 * :Your username is invalid (maximum 5 characters)\r\n"}
        ])
      end)
    end

    test "respects custom max_realname_length configuration" do
      original_user_config = Application.get_env(:elixircd, :user)
      on_exit(fn -> Application.put_env(:elixircd, :user, original_user_config) end)

      Application.put_env(
        :elixircd,
        :user,
        (original_user_config || [])
        |> Keyword.put(:max_realname_length, 20)
      )

      Handshake
      |> expect(:handle, 1, fn updated_user ->
        assert String.length(updated_user.realname) == 20
        assert updated_user.realname == "12345678901234567890"
        :ok
      end)

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)

        long_realname = "123456789012345678901234567890"
        message = %Message{command: "USER", params: ["username", "0", "*"], trailing: long_realname}
        assert :ok = User.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end
end
