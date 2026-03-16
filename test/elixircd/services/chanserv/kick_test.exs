defmodule ElixIRCd.Services.Chanserv.KickTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Services.Chanserv.Kick
  alias ElixIRCd.Tables.RegisteredChannel

  describe "handle/2" do
    test "requires identification and validates syntax" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Kick.handle(user, ["KICK", "#channel", "Target"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You must be identified with NickServ to use this command.\r\n"}
        ])

        identified_user = insert(:user, identified_as: "helper")

        assert :ok = Kick.handle(identified_user, ["KICK"])

        assert_sent_messages([
          {identified_user.pid,
           ":ChanServ!service@irc.test NOTICE #{identified_user.nick} :Insufficient parameters for \x02KICK\x02.\r\n"},
          {identified_user.pid,
           ":ChanServ!service@irc.test NOTICE #{identified_user.nick} :Syntax: \x02KICK <channel> <nickname|mask> [reason]\x02\r\n"}
        ])
      end)
    end

    test "handles missing channels, offline channels, access denial and missing targets" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")

        assert :ok = Kick.handle(user, ["KICK", "#missing", "Target"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#missing\x02 is not registered.\r\n"}
        ])

        insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Kick.handle(user, ["KICK", "#testchannel", "Target"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Access denied for \x02#testchannel\x02.\r\n"}
        ])

        insert(:registered_channel_access, channel_name: "#testchannel", account_name: "helper", flags: "S")

        assert :ok = Kick.handle(user, ["KICK", "#testchannel", "Target"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#testchannel\x02 is not currently in use.\r\n"}
        ])

        channel = insert(:channel, name: "#testchannel")

        assert :ok = Kick.handle(user, ["KICK", channel.name, "Target"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :No matching users for \x02Target\x02 were found on \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "reports when an online nickname is not on the channel" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target = insert(:user)
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "S")

        assert :ok = Kick.handle(user, ["KICK", channel.name, target.nick])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\x02#{target.nick}\x02 is not on \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "kicks by nickname and by mask" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target = insert(:user, hostname: "staff.example.com")
        watcher = insert(:user)
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "S")
        insert(:user_channel, user: target, channel: channel)
        insert(:user_channel, user: watcher, channel: channel)

        assert :ok = Kick.handle(user, ["KICK", channel.name, target.nick, "Reason"])

        assert {:error, :user_channel_not_found} =
                 UserChannels.get_by_user_pid_and_channel_name(target.pid, channel.name)

        assert_sent_messages(
          [
            {target.pid, ":ChanServ!service@irc.test KICK #{channel.name} #{target.nick} :Reason\r\n"},
            {watcher.pid, ":ChanServ!service@irc.test KICK #{channel.name} #{target.nick} :Reason\r\n"},
            {user.pid,
             ":ChanServ!service@irc.test NOTICE #{user.nick} :Kicked \x021\x02 user from \x02#{channel.name}\x02.\r\n"}
          ],
          validate_order?: false
        )

        target2 = insert(:user, hostname: "staff.example.com")
        insert(:user_channel, user: target2, channel: channel)

        assert :ok = Kick.handle(user, ["KICK", channel.name, "*!*@*.example.com"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Kicked \x021\x02 user from \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "kicks multiple matching users with the default reason" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target1 = insert(:user, hostname: "staff.example.com")
        target2 = insert(:user, hostname: "staff.example.com")
        watcher = insert(:user)
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "S")
        insert(:user_channel, user: target1, channel: channel)
        insert(:user_channel, user: target2, channel: channel)
        insert(:user_channel, user: watcher, channel: channel)

        assert :ok = Kick.handle(user, ["KICK", channel.name, "*!*@staff.example.com"])

        assert {:error, :user_channel_not_found} =
                 UserChannels.get_by_user_pid_and_channel_name(target1.pid, channel.name)

        assert {:error, :user_channel_not_found} =
                 UserChannels.get_by_user_pid_and_channel_name(target2.pid, channel.name)

        assert_sent_messages_count_containing(
          watcher.pid,
          ~r/:ChanServ!service@irc\.test KICK #{channel.name} .* :Requested by #{user.nick}/,
          2
        )

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Kicked \x022\x02 users from \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "honors PEACE for protected targets" do
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

        assert :ok = Kick.handle(user, ["KICK", channel.name, target.nick])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#{channel.name}\x02 has \x02PEACE\x02 enabled; you cannot kick a matching protected target.\r\n"}
        ])
      end)
    end
  end
end
