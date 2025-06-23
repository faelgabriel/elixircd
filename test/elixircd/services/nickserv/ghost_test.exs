defmodule ElixIRCd.Services.Nickserv.GhostTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Services.Nickserv.Ghost

  describe "handle/2" do
    test "handles GHOST command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Ghost.handle(user, ["GHOST"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02GHOST\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02GHOST <nick> [password]\x02\r\n"}
        ])
      end)
    end

    test "handles GHOST command for nick that is not online" do
      Memento.transaction!(fn ->
        user = insert(:user)
        non_existing_nick = "non_existing_nick"

        assert :ok = Ghost.handle(user, ["GHOST", non_existing_nick])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{non_existing_nick}\x02 is not online.\r\n"}
        ])
      end)
    end

    test "handles GHOST command for trying to ghost yourself" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Ghost.handle(user, ["GHOST", user.nick])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :You cannot ghost yourself.\r\n"}
        ])
      end)
    end

    test "handles GHOST command for a nick that is not registered" do
      Memento.transaction!(fn ->
        target_user = insert(:user)
        user = insert(:user)

        assert :ok = Ghost.handle(user, ["GHOST", target_user.nick])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{target_user.nick}\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles GHOST command for registered nick without providing password" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        target_user = insert(:user, nick: registered_nick.nickname)
        user = insert(:user)

        assert :ok = Ghost.handle(user, ["GHOST", target_user.nick])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You need to provide a password to ghost \x02#{target_user.nick}\x02.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02GHOST #{target_user.nick} <password>\x02\r\n"}
        ])
      end)
    end

    test "handles GHOST command for registered nick with incorrect password" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        target_user = insert(:user, nick: registered_nick.nickname)
        user = insert(:user)

        assert :ok = Ghost.handle(user, ["GHOST", target_user.nick, "wrong_password"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Invalid password for \x02#{target_user.nick}\x02.\r\n"}
        ])

        assert {:ok, _user} = Users.get_by_pid(target_user.pid)
      end)
    end

    test "handles GHOST command for registered nick with correct password" do
      Memento.transaction!(fn ->
        target_pid = spawn_test_process()

        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        target_user = insert(:user, nick: registered_nick.nickname, pid: target_pid)
        user = insert(:user)

        assert :ok = Ghost.handle(user, ["GHOST", target_user.nick, password])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :User \x02#{target_user.nick}\x02 has been disconnected.\r\n"}
        ])

        assert_disconnect_process_message_sent()
      end)
    end

    test "handles GHOST command when user is already identified as the registered nick" do
      Memento.transaction!(fn ->
        target_pid = spawn_test_process()

        registered_nick = insert(:registered_nick)
        target_user = insert(:user, nick: registered_nick.nickname, pid: target_pid)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Ghost.handle(user, ["GHOST", target_user.nick])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :User \x02#{target_user.nick}\x02 has been disconnected.\r\n"}
        ])

        assert_disconnect_process_message_sent()
      end)
    end
  end

  @spec spawn_test_process() :: pid()
  defp spawn_test_process do
    parent = self()

    spawn(fn ->
      receive do
        message -> send(parent, {:ghost_test, message})
      end
    end)
  end

  @spec assert_disconnect_process_message_sent :: :ok
  defp assert_disconnect_process_message_sent do
    receive do
      {:ghost_test, {:disconnect, message}} ->
        assert message =~ "Killed"
    after
      150 -> flunk("No disconnect message was sent to the target user")
    end
  end
end
