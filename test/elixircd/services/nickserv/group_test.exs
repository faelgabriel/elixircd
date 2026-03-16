defmodule ElixIRCd.Services.Nickserv.GroupTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.NickAccesses
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Services.Nickserv.Group

  describe "handle/2" do
    test "requires identification" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Group.handle(user, ["GROUP"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You must identify to NickServ before using the GROUP command.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Use \x02/msg NickServ IDENTIFY <password>\x02 to identify.\r\n"}
        ])
      end)
    end

    test "groups an unregistered current nick into the authenticated account" do
      Memento.transaction!(fn ->
        account_nick = insert(:registered_nick, nickname: "AccountNick")
        user = insert(:user, nick: "AliasNick", identified_as: account_nick.nickname)

        assert :ok = Group.handle(user, ["GROUP"])

        assert {:ok, grouped_nick} = RegisteredNicks.get_by_nickname("AliasNick")
        assert grouped_nick.account_name == account_nick.account_name

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{user.nick}\x02 has been grouped into account \x02#{account_nick.account_name}\x02.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You can now use it as an alias for your account.\r\n"}
        ])
      end)
    end

    test "rejects grouping a nickname that belongs to another account" do
      Memento.transaction!(fn ->
        account_nick = insert(:registered_nick, nickname: "AccountNick")
        insert(:registered_nick, nickname: "AliasNick", account_name: "OtherAccount")
        user = insert(:user, nick: "AliasNick", identified_as: account_nick.nickname)

        assert :ok = Group.handle(user, ["GROUP"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{user.nick}\x02 is already registered.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :To group it into your current account, repeat the command with that nick's password.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02GROUP [current-nick-password]\x02\r\n"}
        ])
      end)
    end

    test "groups a standalone registered current nick when the nick password is provided" do
      Memento.transaction!(fn ->
        account_nick = insert(:registered_nick, nickname: "AccountNick")
        current_nick_password = "current_password"

        standalone_nick =
          insert(:registered_nick,
            nickname: "AliasNick",
            password_hash: Argon2.hash_pwd_salt(current_nick_password)
          )

        user = insert(:user, nick: standalone_nick.nickname, identified_as: account_nick.nickname)

        assert :ok = Group.handle(user, ["GROUP", current_nick_password])

        assert {:ok, updated_nick} = RegisteredNicks.get_by_nickname(standalone_nick.nickname)
        assert updated_nick.account_name == account_nick.account_name

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{standalone_nick.nickname}\x02 has been grouped into account \x02#{account_nick.account_name}\x02.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You can now use it as an alias for your account.\r\n"}
        ])
      end)
    end

    test "moves account-related state when grouping a standalone registered nick" do
      Memento.transaction!(fn ->
        account_nick = insert(:registered_nick, nickname: "AccountNick")
        current_nick_password = "current_password"

        standalone_nick =
          insert(:registered_nick,
            nickname: "AliasNick",
            password_hash: Argon2.hash_pwd_salt(current_nick_password)
          )

        insert(:nick_access, nickname: standalone_nick.nickname, mask: "*@old.host")
        insert(:nick_access, nickname: account_nick.nickname, mask: "*@existing.host")

        founder_channel = insert(:registered_channel, name: "#founder", founder: standalone_nick.nickname)

        successor_channel =
          insert(:registered_channel, name: "#successor", founder: "OtherFounder", successor: standalone_nick.nickname)

        both_channel =
          insert(:registered_channel,
            name: "#both",
            founder: standalone_nick.nickname,
            successor: standalone_nick.nickname
          )

        identified_user =
          insert(:user,
            nick: "OtherUser",
            identified_as: standalone_nick.nickname,
            capabilities: ["ACCOUNT-NOTIFY"]
          )

        user = insert(:user, nick: standalone_nick.nickname, identified_as: account_nick.nickname)

        assert :ok = Group.handle(user, ["GROUP", current_nick_password])

        {:ok, updated_identified_user} = Users.get_by_pid(identified_user.pid)
        assert updated_identified_user.identified_as == account_nick.nickname

        assert NickAccesses.get_by_account_name(standalone_nick.nickname) == []

        migrated_masks =
          NickAccesses.get_by_account_name(account_nick.nickname)
          |> Enum.map(& &1.mask)

        assert "*@old.host" in migrated_masks
        assert "*@existing.host" in migrated_masks

        {:ok, updated_founder_channel} = RegisteredChannels.get_by_name(founder_channel.name)
        assert updated_founder_channel.founder == account_nick.nickname

        {:ok, updated_successor_channel} = RegisteredChannels.get_by_name(successor_channel.name)
        assert updated_successor_channel.successor == account_nick.nickname

        {:ok, updated_both_channel} = RegisteredChannels.get_by_name(both_channel.name)
        assert updated_both_channel.founder == account_nick.nickname
        assert updated_both_channel.successor == account_nick.nickname
      end)
    end

    test "does not duplicate access entries already present on the destination account" do
      Memento.transaction!(fn ->
        account_nick = insert(:registered_nick, nickname: "AccountNick")
        current_nick_password = "current_password"

        standalone_nick =
          insert(:registered_nick,
            nickname: "AliasNick",
            password_hash: Argon2.hash_pwd_salt(current_nick_password)
          )

        insert(:nick_access, nickname: standalone_nick.nickname, mask: "*@shared.host")
        insert(:nick_access, nickname: account_nick.nickname, mask: "*@shared.host")

        user = insert(:user, nick: standalone_nick.nickname, identified_as: account_nick.nickname)

        assert :ok = Group.handle(user, ["GROUP", current_nick_password])

        matching_entries =
          NickAccesses.get_by_account_name(account_nick.nickname)
          |> Enum.filter(&(&1.mask == "*@shared.host"))

        assert length(matching_entries) == 1
      end)
    end

    test "rejects grouping a registered current nick when the password is invalid" do
      Memento.transaction!(fn ->
        account_nick = insert(:registered_nick, nickname: "AccountNick")
        insert(:registered_nick, nickname: "AliasNick", password_hash: Argon2.hash_pwd_salt("correct_password"))
        user = insert(:user, nick: "AliasNick", identified_as: account_nick.nickname)

        assert :ok = Group.handle(user, ["GROUP", "wrong_password"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Authentication failed. Invalid password for \x02AliasNick\x02.\r\n"}
        ])
      end)
    end

    test "rejects grouping when the current nick account cannot be resolved" do
      Memento.transaction!(fn ->
        account_nick = insert(:registered_nick, nickname: "AccountNick")
        user = insert(:user, nick: "AliasNick", identified_as: account_nick.nickname)

        insert(:registered_nick,
          nickname: "AliasNick",
          account_name: "MissingAccount",
          password_hash: Argon2.hash_pwd_salt("current_password")
        )

        assert :ok = Group.handle(user, ["GROUP", "current_password"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02AliasNick\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "rejects grouping a primary nick that still has grouped aliases" do
      Memento.transaction!(fn ->
        account_nick = insert(:registered_nick, nickname: "AccountNick")
        current_nick_password = "current_password"

        standalone_primary =
          insert(:registered_nick,
            nickname: "AliasNick",
            password_hash: Argon2.hash_pwd_salt(current_nick_password)
          )

        insert(:registered_nick, nickname: "AliasNick2", account_name: standalone_primary.nickname)

        user = insert(:user, nick: standalone_primary.nickname, identified_as: account_nick.nickname)

        assert :ok = Group.handle(user, ["GROUP", current_nick_password])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{standalone_primary.nickname}\x02 is the primary nickname of another account.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Ungroup or drop the other nicknames in that account before grouping this nick.\r\n"}
        ])
      end)
    end

    test "rejects grouping when current nick is the primary nick of the account" do
      Memento.transaction!(fn ->
        account_nick = insert(:registered_nick, nickname: "AccountNick")
        user = insert(:user, nick: account_nick.nickname, identified_as: account_nick.nickname)

        assert :ok = Group.handle(user, ["GROUP"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Your current nickname is already the primary nickname of your account.\r\n"}
        ])
      end)
    end

    test "rejects grouping when nick is already grouped with the same account" do
      Memento.transaction!(fn ->
        account_nick = insert(:registered_nick, nickname: "AccountNick")
        insert(:registered_nick, nickname: "AliasNick", account_name: account_nick.nickname)
        user = insert(:user, nick: "AliasNick", identified_as: account_nick.nickname)

        assert :ok = Group.handle(user, ["GROUP"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02AliasNick\x02 is already grouped with your account.\r\n"}
        ])
      end)
    end

    test "rejects extra parameters" do
      Memento.transaction!(fn ->
        account_nick = insert(:registered_nick, nickname: "AccountNick")
        user = insert(:user, nick: "AliasNick", identified_as: account_nick.nickname)

        assert :ok = Group.handle(user, ["GROUP", "extra", "params"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Too many parameters for \x02GROUP\x02.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02GROUP [current-nick-password]\x02\r\n"}
        ])
      end)
    end

    test "rejects grouping when account is not verified" do
      Memento.transaction!(fn ->
        account_nick =
          insert(:registered_nick,
            nickname: "AccountNick",
            verify_code: "abc123",
            verified_at: nil
          )

        user = insert(:user, nick: "AliasNick", identified_as: account_nick.nickname)

        assert :ok = Group.handle(user, ["GROUP"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Your account \x02#{account_nick.account_name}\x02 has not been verified yet.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Please verify it first with \x02/msg NickServ VERIFY #{account_nick.nickname} <code>\x02\r\n"}
        ])
      end)
    end

    test "reports error when account cannot be resolved" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "NonExistentAccount")

        assert :ok = Group.handle(user, ["GROUP"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Your account could not be resolved. Please try identifying again.\r\n"}
        ])
      end)
    end
  end
end
