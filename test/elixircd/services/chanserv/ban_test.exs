defmodule ElixIRCd.Services.Chanserv.BanTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [normalize_mask: 1, user_mask: 1]

  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Services.Chanserv.Ban
  alias ElixIRCd.Tables.RegisteredChannel

  describe "handle/2" do
    test "requires identification and validates syntax" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Ban.handle(user, ["BAN", "#channel", "Target"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You must be identified with NickServ to use this command.\r\n"}
        ])

        identified_user = insert(:user, identified_as: "founder")

        assert :ok = Ban.handle(identified_user, ["BAN"])

        assert_sent_messages([
          {identified_user.pid,
           ":ChanServ!service@irc.test NOTICE #{identified_user.nick} :Insufficient parameters for \x02BAN\x02.\r\n"},
          {identified_user.pid,
           ":ChanServ!service@irc.test NOTICE #{identified_user.nick} :Syntax: \x02BAN <channel> <nickname|mask>\x02\r\n"}
        ])
      end)
    end

    test "handles missing channels, offline channels, and access denial" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")

        assert :ok = Ban.handle(user, ["BAN", "#missing", "Target"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#missing\x02 is not registered.\r\n"}
        ])

        insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Ban.handle(user, ["BAN", "#testchannel", "Target"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Access denied for \x02#testchannel\x02.\r\n"}
        ])

        insert(:registered_channel_access, channel_name: "#testchannel", account_name: "helper", flags: "S")

        assert :ok = Ban.handle(user, ["BAN", "#testchannel", "Target"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#testchannel\x02 is not currently in use.\r\n"}
        ])
      end)
    end

    test "adds bans by nickname and reports already-set masks" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        watcher = insert(:user)
        target = insert(:user, identified_as: "target")
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "S")
        insert(:user_channel, user: watcher, channel: channel)
        insert(:user_channel, user: target, channel: channel)

        ban_mask = normalize_mask(user_mask(target))

        assert :ok = Ban.handle(user, ["BAN", channel.name, target.nick])

        assert [{_, ^ban_mask, _, _}] =
                 Memento.Query.all(ElixIRCd.Tables.ChannelBan)
                 |> Enum.map(fn ban -> {ban.channel_name_key, ban.mask, ban.setter, ban.created_at} end)

        assert_sent_messages(
          [
            {watcher.pid, ":ChanServ!service@irc.test MODE #{channel.name} +b #{ban_mask}\r\n"},
            {target.pid, ":ChanServ!service@irc.test MODE #{channel.name} +b #{ban_mask}\r\n"},
            {user.pid,
             ":ChanServ!service@irc.test NOTICE #{user.nick} :Ban \x02#{ban_mask}\x02 has been added to \x02#{channel.name}\x02.\r\n"}
          ],
          validate_order?: false
        )

        assert :ok = Ban.handle(user, ["BAN", channel.name, target.nick])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Ban \x02#{ban_mask}\x02 is already set on \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "adds bans from explicit masks" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        channel = insert(:channel, name: "#testchannel")
        mask = normalize_mask("Trouble!*@Example.COM")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "S")

        assert :ok = Ban.handle(user, ["BAN", channel.name, "Trouble!*@Example.COM"])

        assert {:ok, channel_ban} = ChannelBans.get_by_channel_name_key_and_mask(channel.name_key, mask)
        assert channel_ban.mask == mask

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Ban \x02#{mask}\x02 has been added to \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "honors PEACE for matching protected targets" do
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

        assert :ok = Ban.handle(user, ["BAN", channel.name, target.nick])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#{channel.name}\x02 has \x02PEACE\x02 enabled; you cannot ban a matching protected target.\r\n"}
        ])

        assert [] == ChannelBans.get_by_channel_name_key(channel.name_key)
      end)
    end
  end
end
