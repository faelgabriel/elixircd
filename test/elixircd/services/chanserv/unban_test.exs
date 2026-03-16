defmodule ElixIRCd.Services.Chanserv.UnbanTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [normalize_mask: 1, user_mask: 1]

  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Services.Chanserv.Unban

  describe "handle/2" do
    test "requires identification and validates syntax" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Unban.handle(user, ["UNBAN", "#channel"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You must be identified with NickServ to use this command.\r\n"}
        ])

        identified_user = insert(:user, identified_as: "helper")

        assert :ok = Unban.handle(identified_user, ["UNBAN"])

        assert_sent_messages([
          {identified_user.pid,
           ":ChanServ!service@irc.test NOTICE #{identified_user.nick} :Syntax: \x02UNBAN <channel> [nickname|mask]\x02\r\n"}
        ])
      end)
    end

    test "handles missing channels, offline channels, access denial and empty matches" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")

        assert :ok = Unban.handle(user, ["UNBAN", "#missing"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#missing\x02 is not registered.\r\n"}
        ])

        insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Unban.handle(user, ["UNBAN", "#testchannel"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Access denied for \x02#testchannel\x02.\r\n"}
        ])

        insert(:registered_channel_access, channel_name: "#testchannel", account_name: "helper", flags: "S")

        assert :ok = Unban.handle(user, ["UNBAN", "#testchannel"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#testchannel\x02 is not currently in use.\r\n"}
        ])

        channel = insert(:channel, name: "#testchannel")
        watcher = insert(:user)
        insert(:user_channel, user: watcher, channel: channel)

        assert :ok = Unban.handle(user, ["UNBAN", channel.name, "missing!*@*"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :No matching bans were found on \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "removes bans by nickname or exact mask" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target = insert(:user, identified_as: "target")
        watcher = insert(:user)
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "S")
        insert(:user_channel, user: target, channel: channel)
        insert(:user_channel, user: watcher, channel: channel)

        target_mask = normalize_mask(user_mask(target))
        ChannelBans.create(%{channel_name_key: channel.name_key, mask: target_mask, setter: "setter"})
        ChannelBans.create(%{channel_name_key: channel.name_key, mask: "other!*@*", setter: "setter"})

        assert :ok = Unban.handle(user, ["UNBAN", channel.name, target.nick])

        assert_sent_messages(
          [
            {target.pid, ":ChanServ!service@irc.test MODE #{channel.name} -b #{target_mask}\r\n"},
            {watcher.pid, ":ChanServ!service@irc.test MODE #{channel.name} -b #{target_mask}\r\n"},
            {user.pid,
             ":ChanServ!service@irc.test NOTICE #{user.nick} :Removed \x021\x02 ban entry from \x02#{channel.name}\x02.\r\n"}
          ],
          validate_order?: false
        )

        assert :ok = Unban.handle(user, ["UNBAN", channel.name, "other!*@*"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Removed \x021\x02 ban entry from \x02#{channel.name}\x02.\r\n"}
        ])

        assert [] == ChannelBans.get_by_channel_name_key(channel.name_key)
      end)
    end

    test "removes multiple matching bans for the same nickname" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target = insert(:user, ident: "target", hostname: "staff.example.com")
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "S")
        insert(:user_channel, user: target, channel: channel)

        ChannelBans.create(%{channel_name_key: channel.name_key, mask: "#{target.nick}!*@*", setter: "setter"})
        ChannelBans.create(%{channel_name_key: channel.name_key, mask: "*!*@staff.example.com", setter: "setter"})

        assert :ok = Unban.handle(user, ["UNBAN", channel.name, target.nick])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Removed \x022\x02 ban entries from \x02#{channel.name}\x02.\r\n"}
        ])

        assert [] == ChannelBans.get_by_channel_name_key(channel.name_key)
      end)
    end
  end
end
