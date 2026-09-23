defmodule ElixIRCd.Services.Nickserv.DropTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Services.Nickserv.Drop
  alias ElixIRCd.Tables.RegisteredNick.Settings

  describe "handle/2" do
    test "handles DROP command with no parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Drop.handle(user, ["DROP"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{user.nick}\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles DROP command with no parameters for a registered nick" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, nick: registered_nick.nickname, identified_as: registered_nick.nickname, modes: [:r])

        assert :ok = Drop.handle(user, ["DROP"])

        assert_sent_messages([
          {user.pid, ":irc.test MODE #{user.nick} -r\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{registered_nick.nickname}\x02 has been dropped.\r\n"}
        ])

        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname(registered_nick.nickname)

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil
        assert :r not in updated_user.modes
      end)
    end

    test "handles DROP command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        registered_nick = insert(:registered_nick)

        assert :ok = Drop.handle(user, ["DROP", registered_nick.nickname])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02DROP\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02DROP <nickname> <password>\x02\r\n"}
        ])
      end)
    end

    test "handles DROP command for non-registered nickname" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Drop.handle(user, ["DROP", "non_registered_nick"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02non_registered_nick\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles DROP command for identified user dropping their own nick" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, nick: registered_nick.nickname, identified_as: registered_nick.nickname, modes: [:r])

        assert :ok = Drop.handle(user, ["DROP", registered_nick.nickname])

        assert_sent_messages([
          {user.pid, ":irc.test MODE #{user.nick} -r\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{registered_nick.nickname}\x02 has been dropped.\r\n"}
        ])

        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname(registered_nick.nickname)

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil
        assert :r not in updated_user.modes
      end)
    end

    test "handles DROP command for non-identified user with correct password" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user)

        assert :ok = Drop.handle(user, ["DROP", registered_nick.nickname, password])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{registered_nick.nickname}\x02 has been dropped.\r\n"}
        ])

        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
      end)
    end

    test "allows deleting an unverified account with its password" do
      Memento.transaction!(fn ->
        account =
          insert(:registered_nick,
            nickname: "Pending",
            password: "correct_password",
            verify_code: "code",
            verified_at: nil
          )

        user = insert(:user, nick: "Pending")

        assert :ok = Drop.handle(user, ["DROP", account.nickname, "correct_password"])
        assert_sent_message_contains(user.pid, ~r/Nick .* has been dropped/)
        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname(account.nickname)
      end)
    end

    test "requires a secure connection for a SECURE account" do
      Memento.transaction!(fn ->
        registered_nick =
          insert(:registered_nick,
            password: "correct_password",
            settings: Settings.new(%{secure: true})
          )

        user = insert(:user, transport: :tcp)

        assert :ok = Drop.handle(user, ["DROP", registered_nick.nickname, "correct_password"])
        assert_sent_message_contains(user.pid, ~r/requires a secure TLS connection for password authentication/)
      end)
    end

    test "handles DROP command for non-identified user with incorrect password" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user)

        assert :ok = Drop.handle(user, ["DROP", registered_nick.nickname, "wrong_password"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Authentication failed. Invalid password for \x02#{registered_nick.nickname}\x02.\r\n"}
        ])

        assert {:ok, _} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
      end)
    end

    test "handles DROP command when canonical account cannot be resolved" do
      Memento.transaction!(fn ->
        registered_nick =
          insert(:registered_nick,
            nickname: "AliasNick",
            account_name: "MissingAccount",
            password_hash: Argon2.hash_pwd_salt("correct_password")
          )

        user = insert(:user)

        assert :ok = Drop.handle(user, ["DROP", registered_nick.nickname, "correct_password"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{registered_nick.nickname}\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles DROP command for non-identified user without providing password" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user)

        assert :ok = Drop.handle(user, ["DROP", registered_nick.nickname])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02DROP\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02DROP <nickname> <password>\x02\r\n"}
        ])
      end)
    end

    test "handles DROP command that affects currently connected user with that nick" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)

        user = insert(:user)

        target_user =
          insert(:user, nick: registered_nick.nickname, identified_as: registered_nick.nickname, modes: [:r])

        assert :ok = Drop.handle(user, ["DROP", registered_nick.nickname, password])

        {:ok, updated_target_user} = Users.get_by_pid(target_user.pid)
        assert updated_target_user.identified_as == nil
        assert :r not in updated_target_user.modes
      end)
    end

    test "dropping primary nick (sole nick) logs out all users identified to the account" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick, nickname: "PrimaryNick")

        primary_user =
          insert(:user, nick: registered_nick.nickname, identified_as: registered_nick.nickname, modes: [:r])

        alias_user = insert(:user, nick: "OtherNick", identified_as: registered_nick.nickname, modes: [:r])

        assert :ok = Drop.handle(primary_user, ["DROP"])

        {:ok, updated_primary_user} = Users.get_by_pid(primary_user.pid)
        assert updated_primary_user.identified_as == nil
        assert :r not in updated_primary_user.modes

        {:ok, updated_alias_user} = Users.get_by_pid(alias_user.pid)
        assert updated_alias_user.identified_as == nil
        assert :r not in updated_alias_user.modes
      end)
    end

    test "blocks dropping primary nick when grouped aliases exist" do
      Memento.transaction!(fn ->
        primary_nick = insert(:registered_nick, nickname: "PrimaryNick")
        _alias_nick = insert(:registered_nick, nickname: "AliasNick", account_name: primary_nick.nickname)

        user = insert(:user, nick: primary_nick.nickname, identified_as: primary_nick.nickname)

        assert :ok = Drop.handle(user, ["DROP"])

        assert {:ok, _} = RegisteredNicks.get_by_nickname("PrimaryNick")
        assert {:ok, _} = RegisteredNicks.get_by_nickname("AliasNick")

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02PrimaryNick\x02 is the primary nickname for your account.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Ungroup or drop the other nicknames in the group before dropping this one.\r\n"}
        ])
      end)
    end

    test "drops a grouped alias nick without affecting the account" do
      Memento.transaction!(fn ->
        primary_nick = insert(:registered_nick, nickname: "PrimaryNick")
        alias_nick = insert(:registered_nick, nickname: "AliasNick", account_name: primary_nick.nickname)

        user = insert(:user, nick: alias_nick.nickname, identified_as: primary_nick.nickname, modes: [:r])

        assert :ok = Drop.handle(user, ["DROP"])

        assert {:ok, _} = RegisteredNicks.get_by_nickname("PrimaryNick")
        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname("AliasNick")

        {:ok, updated} = Users.get_by_pid(user.pid)
        assert updated.identified_as == primary_nick.account_name
        refute :r in updated.modes

        assert_sent_messages([
          {user.pid, ":irc.test MODE #{user.nick} -r\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02AliasNick\x02 has been dropped.\r\n"}
        ])
      end)
    end

    test "clears the account display nickname when dropping that alias" do
      Memento.transaction!(fn ->
        primary_nick =
          insert(:registered_nick, nickname: "PrimaryNick", settings: Settings.new(%{display: "AliasNick"}))

        alias_nick =
          insert(:registered_nick,
            nickname: "AliasNick",
            account_name: primary_nick.nickname,
            password_hash: primary_nick.password_hash,
            settings: primary_nick.settings
          )

        user = insert(:user, nick: alias_nick.nickname, identified_as: primary_nick.account_name)

        assert :ok = Drop.handle(user, ["DROP", alias_nick.nickname])

        {:ok, updated_primary} = RegisteredNicks.get_by_nickname(primary_nick.nickname)
        assert is_nil(updated_primary.settings.display)
      end)
    end

    test "handles DROP command for user identified as nickname but using different current nick" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)

        user = insert(:user, nick: "different_nick", identified_as: registered_nick.nickname, modes: [:r])

        assert :ok = Drop.handle(user, ["DROP", registered_nick.nickname, password])

        assert_sent_messages([
          {user.pid, ":irc.test MODE #{user.nick} -r\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{registered_nick.nickname}\x02 has been dropped.\r\n"}
        ])

        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname(registered_nick.nickname)

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil
        assert :r not in updated_user.modes
      end)
    end
  end
end
