defmodule ElixIRCd.Services.Nickserv.RecoverTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Services.Nickserv.Recover
  alias ElixIRCd.Tables.RegisteredNick.Settings

  describe "handle/2" do
    test "handles RECOVER command with insufficient parameters" do
      Observability.transaction(fn ->
        user = insert(:user)

        assert :ok = Recover.handle(user, ["RECOVER"])

        assert_sent_messages_after_commit([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02RECOVER\x02.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02RECOVER <nickname> <password>\x02\r\n"}
        ])
      end)
    end

    test "handles RECOVER command for non-registered nickname" do
      Observability.transaction(fn ->
        user = insert(:user)
        non_registered_nick = "non_registered_nick"

        assert :ok = Recover.handle(user, ["RECOVER", non_registered_nick])

        assert_sent_messages_after_commit([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{non_registered_nick}\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles RECOVER command for registered nick without providing password" do
      Observability.transaction(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user)

        assert :ok = Recover.handle(user, ["RECOVER", registered_nick.nickname])

        assert_sent_messages_after_commit([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02RECOVER\x02.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02RECOVER <nickname> <password>\x02\r\n"}
        ])
      end)
    end

    test "handles RECOVER command for registered nick with incorrect password" do
      Observability.transaction(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user)

        assert :ok = Recover.handle(user, ["RECOVER", registered_nick.nickname, "wrong_password"])

        assert_sent_messages_after_commit([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Invalid password for \x02#{registered_nick.nickname}\x02.\r\n"}
        ])
      end)
    end

    test "requires a secure connection for a SECURE account" do
      Observability.transaction(fn ->
        registered_nick =
          insert(:registered_nick,
            password: "correct_password",
            settings: Settings.new(%{secure: true})
          )

        user = insert(:user, transport: :tcp)

        assert :ok = Recover.handle(user, ["RECOVER", registered_nick.nickname, "correct_password"])

        assert_sent_message_contains_after_commit(
          user.pid,
          ~r/requires a secure TLS connection for password authentication/
        )
      end)
    end

    test "handles RECOVER command when user is already identified as the registered nick" do
      Observability.transaction(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Recover.handle(user, ["RECOVER", registered_nick.nickname])

        {:ok, updated_registered_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
        assert updated_registered_nick.reserved_until != nil

        assert_sent_messages_after_commit([
          {user.pid, ~r/NickServ.*NOTICE.*Nick \x02#{registered_nick.nickname}\x02 has been recovered\./},
          {user.pid, ~r/NickServ.*NOTICE.*The nick will be held for you for.*seconds\./},
          {user.pid, ~r/NickServ.*NOTICE.*To use it, type: \x02\/msg NickServ IDENTIFY.*<password>\x02/},
          {user.pid, ~r/NickServ.*NOTICE.*followed by: \x02\/NICK/}
        ])
      end)
    end

    test "handles RECOVER command when user is identified to the grouped nick account" do
      Observability.transaction(fn ->
        primary_nick = insert(:registered_nick, nickname: "PrimaryNick")
        _grouped_nick = insert(:registered_nick, nickname: "AliasNick", account_name: primary_nick.nickname)
        user = insert(:user, identified_as: primary_nick.nickname)

        assert :ok = Recover.handle(user, ["RECOVER", "AliasNick"])

        {:ok, updated_registered_nick} = RegisteredNicks.get_by_nickname("AliasNick")
        assert updated_registered_nick.reserved_until != nil

        assert_sent_messages_after_commit([
          {user.pid, ~r/NickServ.*NOTICE.*Nick \x02AliasNick\x02 has been recovered\./},
          {user.pid, ~r/NickServ.*NOTICE.*The nick will be held for you for.*seconds\./},
          {user.pid, ~r/NickServ.*NOTICE.*To use it, type: \x02\/msg NickServ IDENTIFY AliasNick <password>\x02/},
          {user.pid, ~r/NickServ.*NOTICE.*followed by: \x02\/NICK AliasNick\x02/}
        ])
      end)
    end

    test "handles RECOVER command for registered nick with correct password when nick is not in use" do
      Observability.transaction(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user)

        assert :ok = Recover.handle(user, ["RECOVER", registered_nick.nickname, password])

        {:ok, updated_registered_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
        assert updated_registered_nick.reserved_until != nil

        assert_sent_messages_after_commit([
          {user.pid, ~r/NickServ.*NOTICE.*Nick \x02#{registered_nick.nickname}\x02 has been recovered\./},
          {user.pid, ~r/NickServ.*NOTICE.*The nick will be held for you for.*seconds\./},
          {user.pid, ~r/NickServ.*NOTICE.*To use it, type: \x02\/msg NickServ IDENTIFY.*<password>\x02/},
          {user.pid, ~r/NickServ.*NOTICE.*followed by: \x02\/NICK/}
        ])
      end)
    end

    test "handles RECOVER command when canonical account cannot be resolved" do
      Observability.transaction(fn ->
        insert(:registered_nick,
          nickname: "AliasNick",
          account_name: "MissingAccount",
          password_hash: Argon2.hash_pwd_salt("correct_password")
        )

        user = insert(:user)

        assert :ok = Recover.handle(user, ["RECOVER", "AliasNick", "correct_password"])

        assert_sent_messages_after_commit([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02AliasNick\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles RECOVER command for trying to recover your own session" do
      Observability.transaction(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user, nick: registered_nick.nickname)

        assert :ok = Recover.handle(user, ["RECOVER", registered_nick.nickname, password])

        assert_sent_messages_after_commit([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :You cannot recover your own session.\r\n"}
        ])
      end)
    end

    test "handles RECOVER command for registered nick with correct password when nick is in use" do
      Observability.transaction(fn ->
        target_pid = spawn_test_process()

        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)

        _target_user = insert(:user, nick: registered_nick.nickname, pid: target_pid)
        user = insert(:user)

        assert :ok = Recover.handle(user, ["RECOVER", registered_nick.nickname, password])

        assert_disconnect_after_commit(:recover_test, "Killed")

        {:ok, updated_registered_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
        assert updated_registered_nick.reserved_until != nil

        assert_sent_messages_after_commit([
          {user.pid, ~r/NickServ.*NOTICE.*Nick \x02#{registered_nick.nickname}\x02 has been recovered\./},
          {user.pid, ~r/NickServ.*NOTICE.*The nick will be held for you for.*seconds\./},
          {user.pid, ~r/NickServ.*NOTICE.*To use it, type: \x02\/msg NickServ IDENTIFY.*<password>\x02/},
          {user.pid, ~r/NickServ.*NOTICE.*followed by: \x02\/NICK/}
        ])
      end)
    end
  end

  @spec spawn_test_process() :: pid()
  defp spawn_test_process do
    parent = self()

    spawn(fn ->
      receive do
        message -> send(parent, {:recover_test, message})
      end
    end)
  end
end
