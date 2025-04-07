defmodule ElixIRCd.Services.Nickserv.RegainTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Services.Nickserv.Regain

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
        password = "correct_password"
        password_hash = Pbkdf2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user)
        old_nick = user.nick

        assert :ok = Regain.handle(user, ["REGAIN", registered_nick.nickname, password])

        # User's nick should be updated
        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.nick == registered_nick.nickname

        assert_sent_messages([
          {user.pid, ":#{old_nick}!#{user.ident}@#{user.hostname} NICK #{registered_nick.nickname}\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You have regained the nickname \x02#{registered_nick.nickname}\x02.\r\n"}
        ])
      end)
    end

    test "handles REGAIN command when user is already identified as the registered nick" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)
        old_nick = user.nick

        assert :ok = Regain.handle(user, ["REGAIN", registered_nick.nickname])

        # User's nick should be updated
        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.nick == registered_nick.nickname

        assert_sent_messages([
          {user.pid, ":#{old_nick}!#{user.ident}@#{user.hostname} NICK #{registered_nick.nickname}\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You have regained the nickname \x02#{registered_nick.nickname}\x02.\r\n"}
        ])
      end)
    end

    test "handles REGAIN command for trying to regain your own session" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Pbkdf2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user, nick: registered_nick.nickname)

        assert :ok = Regain.handle(user, ["REGAIN", registered_nick.nickname, password])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :You cannot regain your own session.\r\n"}
        ])
      end)
    end

    test "handles REGAIN command for registered nick with correct password when nick is in use" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Pbkdf2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)

        target_pid = spawn_test_process()
        _target_user = insert(:user, nick: registered_nick.nickname, pid: target_pid)

        user = insert(:user)
        old_nick = user.nick

        assert :ok = Regain.handle(user, ["REGAIN", registered_nick.nickname, password])

        # Check the registered nick is now reserved
        {:ok, updated_registered_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
        assert not is_nil(updated_registered_nick.reserved_until)

        # User's nick should be updated
        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.nick == registered_nick.nickname

        # Since we can't reliably test message delivery to the killed user's process,
        # we'll only verify the messages to the remaining user
        assert_sent_messages([
          {user.pid, ":#{old_nick}!#{user.ident}@#{user.hostname} NICK #{registered_nick.nickname}\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{registered_nick.nickname}\x02 has been regained.\r\n"}
        ])

        # Target user should be killed
        expected_message = "Killed (#{old_nick} (REGAIN command used))"
        assert_received {:regain_test, {:disconnect, ^expected_message}}
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
