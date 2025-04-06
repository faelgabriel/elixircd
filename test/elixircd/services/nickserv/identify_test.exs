defmodule ElixIRCd.Services.Nickserv.IdentifyTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Services.Nickserv.Identify

  describe "handle/2" do
    test "handles IDENTIFY command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Identify.handle(user, ["IDENTIFY"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@server.example.com NOTICE #{user.nick} :Insufficient parameters for \x02IDENTIFY\x02.\r\n"},
          {user.pid,
           ":NickServ!service@server.example.com NOTICE #{user.nick} :Syntax: \x02IDENTIFY [nickname] <password>\x02\r\n"}
        ])
      end)
    end

    test "handles IDENTIFY command when user is already identified" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, nick: registered_nick.nickname, identified_as: registered_nick.nickname)

        assert :ok = Identify.handle(user, ["IDENTIFY", "password"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@server.example.com NOTICE #{user.nick} :You are already identified as \x02#{registered_nick.nickname}\x02.\r\n"}
        ])
      end)
    end

    test "handles IDENTIFY command for unregistered nickname" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Identify.handle(user, ["IDENTIFY", "password"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@server.example.com NOTICE #{user.nick} :Nickname \x02#{user.nick}\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles IDENTIFY command with incorrect password" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Pbkdf2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user, nick: registered_nick.nickname)

        assert :ok = Identify.handle(user, ["IDENTIFY", "wrong_password"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@server.example.com NOTICE #{user.nick} :Password incorrect for \x02#{registered_nick.nickname}\x02.\r\n"}
        ])

        # Check that the user was not identified
        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil
      end)
    end

    test "handles IDENTIFY command with current nickname and correct password" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Pbkdf2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user, nick: registered_nick.nickname)

        assert :ok = Identify.handle(user, ["IDENTIFY", password])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@server.example.com NOTICE #{user.nick} :You are now identified for \x02#{registered_nick.nickname}\x02.\r\n"}
        ])

        # Check that the user was identified
        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == registered_nick.nickname

        # Check that the last_seen_at was updated
        {:ok, updated_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
        assert DateTime.compare(updated_nick.last_seen_at, registered_nick.last_seen_at) == :gt
      end)
    end

    test "handles IDENTIFY command with specific nickname and correct password" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Pbkdf2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user)

        assert :ok = Identify.handle(user, ["IDENTIFY", registered_nick.nickname, password])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@server.example.com NOTICE #{user.nick} :You are now identified for \x02#{registered_nick.nickname}\x02.\r\n"},
          {user.pid,
           ":NickServ!service@server.example.com NOTICE #{user.nick} :Your current nickname will now be recognized with your account.\r\n"}
        ])

        # Check that the user was identified
        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == registered_nick.nickname

        # Check that the last_seen_at was updated
        {:ok, updated_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
        assert DateTime.compare(updated_nick.last_seen_at, registered_nick.last_seen_at) == :gt
      end)
    end

    test "handles IDENTIFY command with specific nickname that is not registered" do
      Memento.transaction!(fn ->
        user = insert(:user)
        non_registered_nick = "non_registered_nick"

        assert :ok = Identify.handle(user, ["IDENTIFY", non_registered_nick, "password"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@server.example.com NOTICE #{user.nick} :Nickname \x02#{non_registered_nick}\x02 is not registered.\r\n"}
        ])

        # Check that the user was not identified
        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil
      end)
    end

    test "handles IDENTIFY command with specific nickname and incorrect password" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Pbkdf2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user)

        assert :ok = Identify.handle(user, ["IDENTIFY", registered_nick.nickname, "wrong_password"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@server.example.com NOTICE #{user.nick} :Password incorrect for \x02#{registered_nick.nickname}\x02.\r\n"}
        ])

        # Check that the user was not identified
        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil
      end)
    end
  end
end
