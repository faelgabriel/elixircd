defmodule ElixIRCd.Services.Chanserv.ClearTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelExcepts
  alias ElixIRCd.Repositories.ChannelInvexes
  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Services.Chanserv.Clear
  alias ElixIRCd.Tables.RegisteredChannel

  describe "handle/2" do
    test "requires identification, validates syntax and unknown subcommands" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Clear.handle(user, ["CLEAR", "#channel", "BANS"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You must be identified with NickServ to use this command.\r\n"}
        ])

        identified_user = insert(:user, identified_as: "helper")

        assert :ok = Clear.handle(identified_user, ["CLEAR"])

        assert_sent_messages([
          {identified_user.pid,
           ":ChanServ!service@irc.test NOTICE #{identified_user.nick} :Insufficient parameters for \x02CLEAR\x02.\r\n"},
          {identified_user.pid,
           ":ChanServ!service@irc.test NOTICE #{identified_user.nick} :Syntax: \x02CLEAR <channel> {BANS|FLAGS|USERS}\x02\r\n"}
        ])

        assert :ok = Clear.handle(identified_user, ["CLEAR", "#channel", "bogus"])

        assert_sent_messages([
          {identified_user.pid,
           ":ChanServ!service@irc.test NOTICE #{identified_user.nick} :Unknown CLEAR subcommand: \x02BOGUS\x02\r\n"},
          {identified_user.pid,
           ":ChanServ!service@irc.test NOTICE #{identified_user.nick} :Syntax: \x02CLEAR <channel> {BANS|FLAGS|USERS}\x02\r\n"}
        ])
      end)
    end

    test "clears live ban-related entries" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        watcher = insert(:user)
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "S")
        insert(:user_channel, user: watcher, channel: channel)
        insert(:channel_ban, channel: channel, mask: "ban!*@*")
        insert(:channel_except, channel: channel, mask: "except!*@*")
        insert(:channel_invex, channel: channel, mask: "invex!*@*")

        assert :ok = Clear.handle(user, ["CLEAR", channel.name, "BANS"])

        assert [] == ChannelBans.get_by_channel_name_key(channel.name_key)
        assert [] == ChannelExcepts.get_by_channel_name_key(channel.name_key)
        assert [] == ChannelInvexes.get_by_channel_name_key(channel.name_key)

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Cleared \x023\x02 ban entries from \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "reports missing, unauthorized, offline, and empty CLEAR BANS states" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")

        assert :ok = Clear.handle(user, ["CLEAR", "#missing", "BANS"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#missing\x02 is not registered.\r\n"}
        ])

        insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Clear.handle(user, ["CLEAR", "#testchannel", "BANS"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Access denied for \x02#testchannel\x02.\r\n"}
        ])

        insert(:registered_channel_access, channel_name: "#testchannel", account_name: "helper", flags: "S")

        assert :ok = Clear.handle(user, ["CLEAR", "#testchannel", "BANS"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#testchannel\x02 is not currently in use.\r\n"}
        ])

        channel = insert(:channel, name: "#testchannel")

        assert :ok = Clear.handle(user, ["CLEAR", channel.name, "BANS"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :There are no ban entries to clear on \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "clears explicit ChanServ flags and handles empty lists" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "manager")
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        insert(:registered_channel_access, channel_name: channel.name, account_name: "manager", flags: "F")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "V")

        assert :ok = Clear.handle(user, ["CLEAR", channel.name, "FLAGS"])

        assert %{} == RegisteredChannelAccesses.get_flags_map_by_channel_name(channel.name)

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Cleared \x022\x02 ChanServ flag entries from \x02#{channel.name}\x02.\r\n"}
        ])

        founder = insert(:user, identified_as: "founder")

        assert :ok = Clear.handle(founder, ["CLEAR", channel.name, "FLAGS"])

        assert_sent_messages([
          {founder.pid,
           ":ChanServ!service@irc.test NOTICE #{founder.nick} :There are no explicit ChanServ flags to clear on \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "reports missing channels and access denial for CLEAR FLAGS" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")

        assert :ok = Clear.handle(user, ["CLEAR", "#missing", "FLAGS"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#missing\x02 is not registered.\r\n"}
        ])

        insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Clear.handle(user, ["CLEAR", "#testchannel", "FLAGS"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Access denied for \x02#testchannel\x02.\r\n"}
        ])
      end)
    end

    test "clears a single explicit ChanServ flag entry" do
      Memento.transaction!(fn ->
        founder = insert(:user, identified_as: "founder")
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "V")

        assert :ok = Clear.handle(founder, ["CLEAR", channel.name, "FLAGS"])

        assert %{} == RegisteredChannelAccesses.get_flags_map_by_channel_name(channel.name)

        assert_sent_messages([
          {founder.pid,
           ":ChanServ!service@irc.test NOTICE #{founder.nick} :Cleared \x021\x02 ChanServ flag entry from \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "clears users and honors PEACE" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target = insert(:user, identified_as: "target")
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel,
          name: channel.name,
          founder: "founder",
          settings: RegisteredChannel.Settings.new(%{peace: true})
        )

        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "S")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "target", flags: "S")
        insert(:user_channel, user: target, channel: channel)

        assert :ok = Clear.handle(user, ["CLEAR", channel.name, "USERS"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#{channel.name}\x02 has \x02PEACE\x02 enabled; you cannot clear users while a protected target matches.\r\n"}
        ])

        founder = insert(:user, identified_as: "founder")

        assert :ok = Clear.handle(founder, ["CLEAR", channel.name, "USERS"])

        assert {:error, :user_channel_not_found} =
                 UserChannels.get_by_user_pid_and_channel_name(target.pid, channel.name)

        assert_sent_messages([
          {founder.pid,
           ":ChanServ!service@irc.test NOTICE #{founder.nick} :Cleared \x021\x02 user from \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "reports missing, unauthorized, offline, and empty CLEAR USERS states" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")

        assert :ok = Clear.handle(user, ["CLEAR", "#missing", "USERS"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#missing\x02 is not registered.\r\n"}
        ])

        insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Clear.handle(user, ["CLEAR", "#testchannel", "USERS"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Access denied for \x02#testchannel\x02.\r\n"}
        ])

        insert(:registered_channel_access, channel_name: "#testchannel", account_name: "helper", flags: "S")

        assert :ok = Clear.handle(user, ["CLEAR", "#testchannel", "USERS"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#testchannel\x02 is not currently in use.\r\n"}
        ])

        channel = insert(:channel, name: "#testchannel")

        assert :ok = Clear.handle(user, ["CLEAR", channel.name, "USERS"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :There are no users to clear on \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "clears multiple users" do
      Memento.transaction!(fn ->
        founder = insert(:user, identified_as: "founder")
        target1 = insert(:user)
        target2 = insert(:user)
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:user_channel, user: target1, channel: channel)
        insert(:user_channel, user: target2, channel: channel)

        assert :ok = Clear.handle(founder, ["CLEAR", channel.name, "USERS"])

        assert {:error, :user_channel_not_found} =
                 UserChannels.get_by_user_pid_and_channel_name(target1.pid, channel.name)

        assert {:error, :user_channel_not_found} =
                 UserChannels.get_by_user_pid_and_channel_name(target2.pid, channel.name)

        assert_sent_messages([
          {founder.pid,
           ":ChanServ!service@irc.test NOTICE #{founder.nick} :Cleared \x022\x02 users from \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end
  end
end
