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
           ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02IDENTIFY\x02.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02IDENTIFY [nickname] <password>\x02\r\n"}
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
           ":NickServ!service@irc.test NOTICE #{user.nick} :You are already identified as \x02#{registered_nick.nickname}\x02.\r\n"}
        ])
      end)
    end

    test "blocks IDENTIFY attempt for different account without logout" do
      Memento.transaction!(fn ->
        current_registered_nick = insert(:registered_nick, nickname: "current_account")
        other_registered_nick = insert(:registered_nick, nickname: "other_account")

        user = insert(:user, identified_as: current_registered_nick.nickname)

        assert :ok = Identify.handle(user, ["IDENTIFY", other_registered_nick.nickname, "password"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You are already identified as \x02#{current_registered_nick.nickname}\x02. Please /msg NickServ LOGOUT first.\r\n"}
        ])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == current_registered_nick.nickname
      end)
    end

    test "handles IDENTIFY command for nickname that is not registered" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Identify.handle(user, ["IDENTIFY", "password"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nickname \x02#{user.nick}\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles IDENTIFY command with incorrect password" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user, nick: registered_nick.nickname)

        assert :ok = Identify.handle(user, ["IDENTIFY", "wrong_password"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Password incorrect for \x02#{registered_nick.nickname}\x02.\r\n"}
        ])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil
      end)
    end

    test "handles IDENTIFY command with current nickname and correct password" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user, nick: registered_nick.nickname)

        assert :ok = Identify.handle(user, ["IDENTIFY", password])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You are now identified for \x02#{registered_nick.nickname}\x02.\r\n"},
          {user.pid, ":irc.test MODE #{user.nick} +r\r\n"}
        ])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == registered_nick.nickname

        {:ok, updated_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
        assert DateTime.compare(updated_nick.last_seen_at, registered_nick.last_seen_at) == :gt
      end)
    end

    test "handles IDENTIFY command with specific nickname and correct password" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user)

        assert :ok = Identify.handle(user, ["IDENTIFY", registered_nick.nickname, password])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You are now identified for \x02#{registered_nick.nickname}\x02.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Your current nickname will now be recognized with your account.\r\n"},
          {user.pid, ":irc.test MODE #{user.nick} +r\r\n"}
        ])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == registered_nick.nickname

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
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nickname \x02#{non_registered_nick}\x02 is not registered.\r\n"}
        ])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil
      end)
    end

    test "handles IDENTIFY command with specific nickname and incorrect password" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user)

        assert :ok = Identify.handle(user, ["IDENTIFY", registered_nick.nickname, "wrong_password"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Password incorrect for \x02#{registered_nick.nickname}\x02.\r\n"}
        ])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil
      end)
    end

    test "notifies users with ACCOUNT-NOTIFY on successful IDENTIFY" do
      original_capabilities = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_capabilities) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_capabilities || [])
        |> Keyword.put(:account_notify, true)
      )

      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)

        identifying_user = insert(:user, nick: registered_nick.nickname, capabilities: ["ACCOUNT-NOTIFY"])
        watcher = insert(:user, capabilities: ["ACCOUNT-NOTIFY"])
        # Users must share a channel to receive ACCOUNT-NOTIFY (and user receives it too)
        channel = insert(:channel, name: "#test")
        insert(:user_channel, user: identifying_user, channel: channel)
        insert(:user_channel, user: watcher, channel: channel)

        assert :ok = Identify.handle(identifying_user, ["IDENTIFY", password])

        assert_sent_messages([
          {identifying_user.pid,
           ":NickServ!service@irc.test NOTICE #{identifying_user.nick} :You are now identified for \x02#{registered_nick.nickname}\x02.\r\n"},
          {identifying_user.pid, ":irc.test MODE #{identifying_user.nick} +r\r\n"},
          {identifying_user.pid,
           ":#{identifying_user.nick}!#{String.slice(identifying_user.ident, 0..9)}@#{identifying_user.hostname} ACCOUNT #{registered_nick.nickname}\r\n"},
          {watcher.pid,
           ":#{identifying_user.nick}!#{String.slice(identifying_user.ident, 0..9)}@#{identifying_user.hostname} ACCOUNT #{registered_nick.nickname}\r\n"}
        ])
      end)
    end
  end
end
