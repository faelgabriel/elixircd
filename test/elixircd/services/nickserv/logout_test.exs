defmodule ElixIRCd.Services.Nickserv.LogoutTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Services.Nickserv.Logout

  describe "handle/2" do
    test "handles LOGOUT command when user is not identified" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Logout.handle(user, ["LOGOUT"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :You are not identified to any nickname.\r\n"}
        ])
      end)
    end

    test "handles LOGOUT command when user is identified" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname, modes: ["r"])

        assert :ok = Logout.handle(user, ["LOGOUT"])

        # Expected order: MODE -r → ACCOUNT * → RPL_LOGGEDOUT (901) → NOTICE
        assert_sent_messages([
          {user.pid, ":irc.test MODE #{user.nick} -r\r\n"},
          {user.pid, ":#{user.nick}!#{String.slice(user.ident, 0..9)}@#{user.hostname} ACCOUNT *\r\n"},
          {user.pid,
           ":irc.test 901 #{user.nick} #{user.nick}!#{String.slice(user.ident, 0..9)}@#{user.hostname} :You are now logged out (was: #{registered_nick.nickname})\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You are now logged out from \x02#{registered_nick.nickname}\x02.\r\n"}
        ])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil
        assert "r" not in updated_user.modes
      end)
    end

    test "handles LOGOUT command when user is identified but doesn't have +r mode" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname, modes: [])

        assert :ok = Logout.handle(user, ["LOGOUT"])

        # Expected order: MODE -r → ACCOUNT * → RPL_LOGGEDOUT (901) → NOTICE
        assert_sent_messages([
          {user.pid, ":irc.test MODE #{user.nick} -r\r\n"},
          {user.pid, ":#{user.nick}!#{String.slice(user.ident, 0..9)}@#{user.hostname} ACCOUNT *\r\n"},
          {user.pid,
           ":irc.test 901 #{user.nick} #{user.nick}!#{String.slice(user.ident, 0..9)}@#{user.hostname} :You are now logged out (was: #{registered_nick.nickname})\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You are now logged out from \x02#{registered_nick.nickname}\x02.\r\n"}
        ])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil
        assert updated_user.modes == []
      end)
    end

    test "handles LOGOUT command with extra parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Logout.handle(user, ["LOGOUT", "extra", "params"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Too many parameters for \x02LOGOUT\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02LOGOUT\x02\r\n"}
        ])
      end)
    end

    test "sends ACCOUNT * to self even when account-notify is disabled" do
      original_capabilities = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_capabilities) end)

      # Disable account-notify
      Application.put_env(
        :elixircd,
        :capabilities,
        (original_capabilities || [])
        |> Keyword.put(:account_notify, false)
      )

      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname, modes: ["r"])

        assert :ok = Logout.handle(user, ["LOGOUT"])

        # ACCOUNT * should still be sent to self even if account-notify is disabled
        assert_sent_messages([
          {user.pid, ":irc.test MODE #{user.nick} -r\r\n"},
          {user.pid, ":#{user.nick}!#{String.slice(user.ident, 0..9)}@#{user.hostname} ACCOUNT *\r\n"},
          {user.pid,
           ":irc.test 901 #{user.nick} #{user.nick}!#{String.slice(user.ident, 0..9)}@#{user.hostname} :You are now logged out (was: #{registered_nick.nickname})\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You are now logged out from \x02#{registered_nick.nickname}\x02.\r\n"}
        ])
      end)
    end

    test "notifies users with ACCOUNT-NOTIFY on LOGOUT" do
      original_capabilities = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_capabilities) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_capabilities || [])
        |> Keyword.put(:account_notify, true)
      )

      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)

        logging_out_user =
          insert(:user, identified_as: registered_nick.nickname, modes: ["r"], capabilities: ["ACCOUNT-NOTIFY"])

        watcher = insert(:user, capabilities: ["ACCOUNT-NOTIFY"])
        # Users must share a channel to receive ACCOUNT-NOTIFY (and user receives it too)
        channel = insert(:channel, name: "#test")
        insert(:user_channel, user: logging_out_user, channel: channel)
        insert(:user_channel, user: watcher, channel: channel)

        assert :ok = Logout.handle(logging_out_user, ["LOGOUT"])

        # Expected order: MODE -r → ACCOUNT * (self) → ACCOUNT * (watcher) → RPL_LOGGEDOUT (901) → NOTICE
        assert_sent_messages([
          {logging_out_user.pid, ":irc.test MODE #{logging_out_user.nick} -r\r\n"},
          {logging_out_user.pid,
           ":#{logging_out_user.nick}!#{String.slice(logging_out_user.ident, 0..9)}@#{logging_out_user.hostname} ACCOUNT *\r\n"},
          {watcher.pid,
           ":#{logging_out_user.nick}!#{String.slice(logging_out_user.ident, 0..9)}@#{logging_out_user.hostname} ACCOUNT *\r\n"},
          {logging_out_user.pid,
           ":irc.test 901 #{logging_out_user.nick} #{logging_out_user.nick}!#{String.slice(logging_out_user.ident, 0..9)}@#{logging_out_user.hostname} :You are now logged out (was: #{registered_nick.nickname})\r\n"},
          {logging_out_user.pid,
           ":NickServ!service@irc.test NOTICE #{logging_out_user.nick} :You are now logged out from \x02#{registered_nick.nickname}\x02.\r\n"}
        ])
      end)
    end
  end
end
