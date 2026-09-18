defmodule ElixIRCd.Services.Nickserv.UngroupTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Services.Nickserv.Ungroup
  alias ElixIRCd.Tables.RegisteredNick.Settings

  describe "handle/2" do
    test "ungroups the current nickname from the authenticated account" do
      Memento.transaction!(fn ->
        account_nick = insert(:registered_nick, nickname: "AccountNick")
        grouped_nick = insert(:registered_nick, nickname: "AliasNick", account_name: account_nick.nickname)

        user =
          insert(:user, nick: grouped_nick.nickname, identified_as: account_nick.nickname, sasl_authenticated: true)

        assert :ok = Ungroup.handle(user, ["UNGROUP"])

        assert {:ok, updated_nick} = RegisteredNicks.get_by_nickname(grouped_nick.nickname)
        assert updated_nick.account_name == grouped_nick.nickname

        assert {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == grouped_nick.nickname
        assert updated_user.sasl_authenticated == false

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{grouped_nick.nickname}\x02 has been removed from account \x02#{account_nick.account_name}\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :It is now a separate NickServ account.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Your current session is now identified for \x02#{grouped_nick.nickname}\x02.\r\n"}
        ])
      end)
    end

    test "clears a display nickname when that alias is ungrouped" do
      Memento.transaction!(fn ->
        account_nick =
          insert(:registered_nick, nickname: "AccountNick", settings: Settings.new(%{display: "AliasNick"}))

        grouped_nick =
          insert(:registered_nick,
            nickname: "AliasNick",
            account_name: account_nick.nickname,
            password_hash: account_nick.password_hash,
            settings: account_nick.settings
          )

        user = insert(:user, nick: grouped_nick.nickname, identified_as: account_nick.nickname)

        assert :ok = Ungroup.handle(user, ["UNGROUP"])

        {:ok, updated_account} = RegisteredNicks.get_by_nickname(account_nick.nickname)
        {:ok, updated_alias} = RegisteredNicks.get_by_nickname(grouped_nick.nickname)
        assert is_nil(updated_account.settings.display)
        assert is_nil(updated_alias.settings.display)
      end)
    end

    test "refuses to ungroup the primary nickname" do
      Memento.transaction!(fn ->
        account_nick = insert(:registered_nick, nickname: "AccountNick")
        user = insert(:user, nick: account_nick.nickname, identified_as: account_nick.nickname)

        assert :ok = Ungroup.handle(user, ["UNGROUP"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You cannot ungroup the primary nickname of your account.\r\n"}
        ])
      end)
    end

    test "requires identification" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Ungroup.handle(user, ["UNGROUP"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You must identify to NickServ before using the UNGROUP command.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Use \x02/msg NickServ IDENTIFY <password>\x02 to identify.\r\n"}
        ])
      end)
    end

    test "reports error when current nick is not registered" do
      Memento.transaction!(fn ->
        account_nick = insert(:registered_nick, nickname: "AccountNick")
        user = insert(:user, nick: "UnregisteredNick", identified_as: account_nick.nickname)

        assert :ok = Ungroup.handle(user, ["UNGROUP"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02UnregisteredNick\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "reports error when nick does not belong to authenticated account" do
      Memento.transaction!(fn ->
        account_nick = insert(:registered_nick, nickname: "AccountNick")
        other_nick = insert(:registered_nick, nickname: "OtherNick")
        user = insert(:user, nick: other_nick.nickname, identified_as: account_nick.nickname)

        assert :ok = Ungroup.handle(user, ["UNGROUP"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02OtherNick\x02 does not belong to your account.\r\n"}
        ])
      end)
    end

    test "rejects ungrouping when account is not verified" do
      Memento.transaction!(fn ->
        account_nick =
          insert(:registered_nick,
            nickname: "AccountNick",
            verify_code: "abc123",
            verified_at: nil
          )

        grouped_nick = insert(:registered_nick, nickname: "AliasNick", account_name: account_nick.nickname)

        user =
          insert(:user, nick: grouped_nick.nickname, identified_as: account_nick.nickname)

        assert :ok = Ungroup.handle(user, ["UNGROUP"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Your account \x02#{account_nick.account_name}\x02 has not been verified yet.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Please verify it first with \x02/msg NickServ VERIFY #{account_nick.nickname} <code>\x02\r\n"}
        ])
      end)
    end

    test "rejects extra parameters" do
      Memento.transaction!(fn ->
        account_nick = insert(:registered_nick, nickname: "AccountNick")
        user = insert(:user, identified_as: account_nick.nickname)

        assert :ok = Ungroup.handle(user, ["UNGROUP", "extra"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Too many parameters for \x02UNGROUP\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02UNGROUP\x02\r\n"}
        ])
      end)
    end

    test "reports error when authenticated account cannot be resolved" do
      Memento.transaction!(fn ->
        insert(:registered_nick, nickname: "AliasNick", account_name: "MissingAccount")
        user = insert(:user, nick: "AliasNick", identified_as: "MissingAccount")

        assert :ok = Ungroup.handle(user, ["UNGROUP"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Your account could not be resolved. Please try identifying again.\r\n"}
        ])
      end)
    end
  end
end
