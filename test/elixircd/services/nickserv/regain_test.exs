defmodule ElixIRCd.Services.Nickserv.RegainTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Services.Nickserv.Regain

  setup :verify_on_exit!

  describe "handle/2" do
    test "handles REGAIN command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Regain.handle(user, ["REGAIN"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02REGAIN\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02REGAIN <nickname> <password>\x02\r\n"}
        ])
      end)
    end

    test "handles REGAIN command for non-registered nickname" do
      Memento.transaction!(fn ->
        user = insert(:user)
        non_registered_nick = "non_registered_nick"

        assert :ok = Regain.handle(user, ["REGAIN", non_registered_nick])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{non_registered_nick}\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles REGAIN command for registered nick without providing password" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user)

        assert :ok = Regain.handle(user, ["REGAIN", registered_nick.nickname])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02REGAIN\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02REGAIN <nickname> <password>\x02\r\n"}
        ])
      end)
    end

    test "handles REGAIN command for registered nick with incorrect password" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Pbkdf2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user)

        assert :ok = Regain.handle(user, ["REGAIN", registered_nick.nickname, "wrong_password"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Invalid password for \x02#{registered_nick.nickname}\x02.\r\n"}
        ])
      end)
    end

    test "handles REGAIN command for registered nick with correct password when nick is not in use" do
      Memento.transaction!(fn ->
        Dispatcher
        |> expect(:broadcast, fn _message, _recipients -> :ok end)

        password = "correct_password"
        password_hash = Pbkdf2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user)

        Users
        |> expect(:get_by_nick, fn _nick -> {:error, :user_not_found} end)

        Users
        |> expect(:update, fn _user, _params ->
          Map.merge(user, %{nick: registered_nick.nickname})
        end)

        assert :ok = Regain.handle(user, ["REGAIN", registered_nick.nickname, password])
      end)
    end

    test "handles REGAIN command when user is already identified as the registered nick" do
      Memento.transaction!(fn ->
        Dispatcher
        |> expect(:broadcast, fn _message, _recipients -> :ok end)

        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        Users
        |> expect(:get_by_nick, fn _nick -> {:error, :user_not_found} end)

        Users
        |> expect(:update, fn _user, params ->
          Map.merge(user, params)
        end)

        assert :ok = Regain.handle(user, ["REGAIN", registered_nick.nickname])
      end)
    end

    test "handles REGAIN command for trying to regain your own session" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, nick: registered_nick.nickname)

        Users
        |> expect(:get_by_nick, fn nick ->
          if nick == registered_nick.nickname, do: {:ok, user}, else: {:error, :user_not_found}
        end)

        assert :ok = Regain.handle(user, ["REGAIN", registered_nick.nickname])
      end)
    end

    test "handles REGAIN command for registered nick with correct password when nick is in use" do
      Memento.transaction!(fn ->
        Dispatcher
        |> expect(:broadcast, fn _message, _recipients -> :ok end)

        target_pid = spawn_test_process()

        password = "correct_password"
        password_hash = Pbkdf2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)

        target_user = insert(:user, nick: registered_nick.nickname, pid: target_pid)
        user = insert(:user)

        Users
        |> expect(:get_by_nick, fn nick ->
          if nick == registered_nick.nickname, do: {:ok, target_user}, else: {:error, :user_not_found}
        end)

        RegisteredNicks
        |> expect(:update, fn _reg_nick, _params ->
          Map.merge(registered_nick, %{reserved_until: DateTime.utc_now()})
        end)

        Users
        |> expect(:update, fn _user, _params ->
          Map.merge(user, %{nick: registered_nick.nickname})
        end)

        assert :ok = Regain.handle(user, ["REGAIN", registered_nick.nickname, password])
      end)
    end
  end

  @spec spawn_test_process() :: pid()
  defp spawn_test_process do
    parent = self()

    spawn(fn ->
      receive do
        message -> send(parent, {:regain_test, message})
      end
    end)
  end
end
