defmodule ElixIRCd.Services.Chanserv.SyncTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Services.Chanserv.Sync
  alias ElixIRCd.Tables.RegisteredNick.Settings

  describe "handle/2" do
    test "requires identification and validates syntax" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Sync.handle(user, ["SYNC", "#channel"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You must be identified with NickServ to use this command.\r\n"}
        ])

        identified_user = insert(:user, identified_as: "helper")

        assert :ok = Sync.handle(identified_user, ["SYNC"])

        assert_sent_messages([
          {identified_user.pid,
           ":ChanServ!service@irc.test NOTICE #{identified_user.nick} :Syntax: \x02SYNC <channel>\x02\r\n"}
        ])
      end)
    end

    test "handles missing channels, offline channels and access denial" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")

        assert :ok = Sync.handle(user, ["SYNC", "#missing"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#missing\x02 is not registered.\r\n"}
        ])

        insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Sync.handle(user, ["SYNC", "#testchannel"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Access denied for \x02#testchannel\x02.\r\n"}
        ])

        insert(:registered_channel_access, channel_name: "#testchannel", account_name: "helper", flags: "S")

        assert :ok = Sync.handle(user, ["SYNC", "#testchannel"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#testchannel\x02 is not currently in use.\r\n"}
        ])
      end)
    end

    test "synchronizes live +o/+v modes with the ChanServ access list" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        founder = insert(:user, identified_as: "founder")
        voiced = insert(:user, identified_as: "voiced")
        guest = insert(:user, identified_as: nil)
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "S")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "voiced", flags: "V")
        insert(:user_channel, user: founder, channel: channel, modes: [:v])
        insert(:user_channel, user: voiced, channel: channel)
        insert(:user_channel, user: guest, channel: channel, modes: [:o])

        assert :ok = Sync.handle(user, ["SYNC", channel.name])

        assert {:ok, founder_channel} = UserChannels.get_by_user_pid_and_channel_name(founder.pid, channel.name)
        assert {:ok, voiced_channel} = UserChannels.get_by_user_pid_and_channel_name(voiced.pid, channel.name)
        assert {:ok, guest_channel} = UserChannels.get_by_user_pid_and_channel_name(guest.pid, channel.name)

        assert :o in founder_channel.modes
        assert :v not in founder_channel.modes
        assert :v in voiced_channel.modes
        assert guest_channel.modes == []

        assert_sent_messages_count_containing(founder.pid, ~r/:ChanServ!service@irc\.test MODE #{channel.name}/, 4)

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Synchronized \x023\x02 users on \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "reports when a channel is already synchronized" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        founder = insert(:user, identified_as: "founder")
        voiced = insert(:user, identified_as: "voiced")
        guest = insert(:user)
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "S")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "voiced", flags: "V")
        insert(:user_channel, user: founder, channel: channel, modes: [:o])
        insert(:user_channel, user: voiced, channel: channel, modes: [:v])
        insert(:user_channel, user: guest, channel: channel)

        assert :ok = Sync.handle(user, ["SYNC", channel.name])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#{channel.name}\x02 is already synchronized.\r\n"}
        ])
      end)
    end

    test "skips users that quit during SYNC instead of crashing" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        founder = insert(:user, identified_as: "founder")
        quitter = insert(:user)
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "S")
        insert(:user_channel, user: founder, channel: channel, modes: [:o])
        insert(:user_channel, user: quitter, channel: channel)

        # Simulate a quit racing the SYNC snapshot (membership row outlives the user row).
        Users.delete(quitter)

        assert :ok = Sync.handle(user, ["SYNC", channel.name])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#{channel.name}\x02 is already synchronized.\r\n"}
        ])
      end)
    end

    test "reports a singular synchronized user count" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        voiced = insert(:user, identified_as: "voiced")
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "S")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "voiced", flags: "V")
        insert(:user_channel, user: voiced, channel: channel)

        assert :ok = Sync.handle(user, ["SYNC", channel.name])

        assert {:ok, voiced_channel} = UserChannels.get_by_user_pid_and_channel_name(voiced.pid, channel.name)
        assert :v in voiced_channel.modes

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Synchronized \x021\x02 user on \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "does not restore operator status for NEVEROP accounts and keeps their change quiet" do
      Memento.transaction!(fn ->
        founder =
          insert(:registered_nick,
            nickname: "founder",
            settings: Settings.new(%{never_op: true, quiet_chg: true})
          )

        user = insert(:user, nick: "founder", identified_as: founder.account_name)
        watcher = insert(:user, nick: "watcher")
        channel = insert(:channel, name: "#never-op")

        insert(:registered_channel, name: channel.name, founder: founder.account_name)
        insert(:user_channel, user: user, channel: channel, modes: [:o])
        insert(:user_channel, user: watcher, channel: channel)

        assert :ok = Sync.handle(user, ["SYNC", channel.name])

        {:ok, updated_membership} = UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name)
        assert updated_membership.modes == []
        assert_sent_messages_count_containing(user.pid, ~r/ MODE /, 0)
        assert_sent_message_contains(watcher.pid, ~r/ MODE #never-op -o founder/)
      end)
    end
  end
end
