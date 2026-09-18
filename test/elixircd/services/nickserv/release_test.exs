defmodule ElixIRCd.Services.Nickserv.ReleaseTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Nickserv.Release
  alias ElixIRCd.Tables.RegisteredNick.Settings

  describe "handle/2" do
    test "handles RELEASE command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Release.handle(user, ["RELEASE"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02RELEASE\x02.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02RELEASE <nickname> <password>\x02\r\n"}
        ])
      end)
    end

    test "handles RELEASE command for non-registered nickname" do
      Memento.transaction!(fn ->
        user = insert(:user)
        non_registered_nick = "non_registered_nick"

        assert :ok = Release.handle(user, ["RELEASE", non_registered_nick])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{non_registered_nick}\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles RELEASE command for nickname with no reservation" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick, reserved_until: nil)
        user = insert(:user)

        assert :ok = Release.handle(user, ["RELEASE", registered_nick.nickname])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{registered_nick.nickname}\x02 is not being held.\r\n"}
        ])
      end)
    end

    test "handles RELEASE command when user is not identified as the registered nick" do
      Memento.transaction!(fn ->
        reserved_until = DateTime.utc_now() |> DateTime.add(300)
        registered_nick = insert(:registered_nick, reserved_until: reserved_until)
        user = insert(:user)

        assert :ok = Release.handle(user, ["RELEASE", registered_nick.nickname])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02RELEASE\x02.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02RELEASE <nickname> <password>\x02\r\n"}
        ])
      end)
    end

    test "handles RELEASE command successfully when user is identified" do
      Memento.transaction!(fn ->
        reserved_until = DateTime.utc_now() |> DateTime.add(300)
        registered_nick = insert(:registered_nick, reserved_until: reserved_until)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Release.handle(user, ["RELEASE", registered_nick.nickname])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{registered_nick.nickname}\x02 has been released.\r\n"}
        ])
      end)
    end

    test "handles RELEASE command when user is identified to the grouped nick account" do
      Memento.transaction!(fn ->
        reserved_until = DateTime.utc_now() |> DateTime.add(300)
        primary_nick = insert(:registered_nick, nickname: "PrimaryNick")

        _grouped_nick =
          insert(:registered_nick,
            nickname: "AliasNick",
            account_name: primary_nick.nickname,
            reserved_until: reserved_until
          )

        user = insert(:user, identified_as: primary_nick.nickname)

        assert :ok = Release.handle(user, ["RELEASE", "AliasNick"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02AliasNick\x02 has been released.\r\n"}
        ])
      end)
    end

    test "handles RELEASE command with correct password" do
      Memento.transaction!(fn ->
        reserved_until = DateTime.utc_now() |> DateTime.add(300)
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)

        registered_nick =
          insert(:registered_nick,
            reserved_until: reserved_until,
            password_hash: password_hash
          )

        user = insert(:user)

        assert :ok = Release.handle(user, ["RELEASE", registered_nick.nickname, password])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{registered_nick.nickname}\x02 has been released.\r\n"}
        ])
      end)
    end

    test "requires a secure connection for a SECURE account" do
      Memento.transaction!(fn ->
        reserved_until = DateTime.utc_now() |> DateTime.add(300)

        registered_nick =
          insert(:registered_nick,
            reserved_until: reserved_until,
            password: "correct_password",
            settings: Settings.new(%{secure: true})
          )

        user = insert(:user, transport: :tcp)

        assert :ok = Release.handle(user, ["RELEASE", registered_nick.nickname, "correct_password"])
        assert_sent_message_contains(user.pid, ~r/requires a secure TLS connection for password authentication/)
      end)
    end

    test "handles RELEASE command with incorrect password" do
      Memento.transaction!(fn ->
        reserved_until = DateTime.utc_now() |> DateTime.add(300)
        correct_password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(correct_password)

        registered_nick =
          insert(:registered_nick,
            reserved_until: reserved_until,
            password_hash: password_hash
          )

        user = insert(:user)
        wrong_password = "wrong_password"

        assert :ok = Release.handle(user, ["RELEASE", registered_nick.nickname, wrong_password])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Invalid password for \x02#{registered_nick.nickname}\x02.\r\n"}
        ])
      end)
    end

    test "handles RELEASE command when canonical account cannot be resolved" do
      Memento.transaction!(fn ->
        reserved_until = DateTime.utc_now() |> DateTime.add(300)

        insert(:registered_nick,
          nickname: "AliasNick",
          account_name: "MissingAccount",
          reserved_until: reserved_until,
          password_hash: Argon2.hash_pwd_salt("correct_password")
        )

        user = insert(:user)

        assert :ok = Release.handle(user, ["RELEASE", "AliasNick", "correct_password"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02AliasNick\x02 is not registered.\r\n"}
        ])
      end)
    end
  end
end
