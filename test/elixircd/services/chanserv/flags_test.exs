defmodule ElixIRCd.Services.Chanserv.FlagsTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Services.Chanserv.Flags

  describe "handle/2" do
    test "requires the user to be identified" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Flags.handle(user, ["FLAGS", "#channel"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You must be identified with NickServ to use this command.\r\n"}
        ])
      end)
    end

    test "shows syntax with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "founder")

        assert :ok = Flags.handle(user, ["FLAGS"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02FLAGS\x02.\r\n"},
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02FLAGS <channel> [nickname [flags]]\x02\r\n"}
        ])
      end)
    end

    test "lists the founder and explicit entries" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: "founder")

        channel =
          insert(:registered_channel,
            name: "#testchannel",
            founder: "founder"
          )

        insert(:registered_channel_access, channel_name: channel.name, account_name: helper.account_name, flags: "VA")

        assert :ok = Flags.handle(user, ["FLAGS", channel.name])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Flags for \x02#{channel.name}\x02:\r\n"},
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Founder: \x02founder\x02 -> \x02VAFST\x02 (implicit)\r\n"},
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :1. \x02#{helper.account_name}\x02 -> \x02VA\x02\r\n"},
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :End of flag list.\r\n"}
        ])
      end)
    end

    test "shows a specific account flag set" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: "founder")

        channel =
          insert(:registered_channel,
            name: "#testchannel",
            founder: "founder"
          )

        insert(:registered_channel_access, channel_name: channel.name, account_name: helper.account_name, flags: "VA")

        assert :ok = Flags.handle(user, ["FLAGS", channel.name, helper.nickname])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Flags for \x02#{helper.account_name}\x02 on \x02#{channel.name}\x02: \x02VA\x02\r\n"}
        ])
      end)
    end

    test "shows when an account has no explicit flags" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: "founder")
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Flags.handle(user, ["FLAGS", channel.name, helper.nickname])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\x02#{helper.account_name}\x02 has no explicit flags on \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "updates flags incrementally and clears them" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: "founder")

        channel =
          insert(:registered_channel,
            name: "#testchannel",
            founder: "founder"
          )

        insert(:registered_channel_access, channel_name: channel.name, account_name: helper.account_name, flags: "V")

        assert :ok = Flags.handle(user, ["FLAGS", channel.name, helper.nickname, "+AF"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Flags for \x02#{helper.account_name}\x02 on \x02#{channel.name}\x02 are now \x02VAF\x02.\r\n"}
        ])

        flags_map = RegisteredChannelAccesses.get_flags_map_by_channel_name(channel.name)
        assert flags_map[helper.account_name] == "VAF"

        assert :ok = Flags.handle(user, ["FLAGS", channel.name, helper.nickname, "OFF"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :All explicit flags for \x02#{helper.account_name}\x02 on \x02#{channel.name}\x02 have been cleared.\r\n"}
        ])

        assert %{} == RegisteredChannelAccesses.get_flags_map_by_channel_name(channel.name)
      end)
    end

    test "rejects invalid flag strings" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: "founder")
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Flags.handle(user, ["FLAGS", channel.name, helper.nickname, "+Z"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Invalid flags. Supported flags are \x02VAFST\x02, and you may use + or - prefixes.\r\n"}
        ])
      end)
    end

    test "handles missing channels, missing nicknames and access denial" do
      Memento.transaction!(fn ->
        founder_nick = insert(:registered_nick, nickname: "FounderNick", account_name: "founder")
        helper = insert(:registered_nick, nickname: "Helper")
        guest = insert(:user, identified_as: "guest")
        founder = insert(:user, identified_as: "founder")
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Flags.handle(founder, ["FLAGS", "#missing"])

        assert_sent_messages([
          {founder.pid,
           ":ChanServ!service@irc.test NOTICE #{founder.nick} :Channel \x02#missing\x02 is not registered.\r\n"}
        ])

        assert :ok = Flags.handle(founder, ["FLAGS", channel.name, "missing"])

        assert_sent_messages([
          {founder.pid,
           ":ChanServ!service@irc.test NOTICE #{founder.nick} :The nickname \x02missing\x02 is not registered.\r\n"}
        ])

        assert :ok = Flags.handle(guest, ["FLAGS", channel.name])

        assert_sent_messages([
          {guest.pid, ":ChanServ!service@irc.test NOTICE #{guest.nick} :Access denied for \x02#{channel.name}\x02.\r\n"}
        ])

        assert :ok = Flags.handle(guest, ["FLAGS", channel.name, helper.nickname, "VA"])

        assert_sent_messages([
          {guest.pid, ":ChanServ!service@irc.test NOTICE #{guest.nick} :Access denied for \x02#{channel.name}\x02.\r\n"}
        ])

        assert :ok = Flags.handle(founder, ["FLAGS", channel.name, founder_nick.nickname])

        assert_sent_messages([
          {founder.pid,
           ":ChanServ!service@irc.test NOTICE #{founder.nick} :Flags for \x02founder\x02 on \x02#{channel.name}\x02: \x02VAFST\x02 \(implicit founder flags\)\r\n"}
        ])

        assert :ok = Flags.handle(founder, ["FLAGS", channel.name, "missing", "VA"])

        assert_sent_messages([
          {founder.pid,
           ":ChanServ!service@irc.test NOTICE #{founder.nick} :The nickname \x02missing\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles specific-view and update requests for missing channels and denied lookups" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        founder = insert(:user, identified_as: "founder")
        guest = insert(:user, identified_as: "guest")
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Flags.handle(founder, ["FLAGS", "#missing", helper.nickname])

        assert_sent_messages([
          {founder.pid,
           ":ChanServ!service@irc.test NOTICE #{founder.nick} :Channel \x02#missing\x02 is not registered.\r\n"}
        ])

        assert :ok = Flags.handle(founder, ["FLAGS", "#missing", helper.nickname, "VA"])

        assert_sent_messages([
          {founder.pid,
           ":ChanServ!service@irc.test NOTICE #{founder.nick} :Channel \x02#missing\x02 is not registered.\r\n"}
        ])

        assert :ok = Flags.handle(guest, ["FLAGS", channel.name, helper.nickname])

        assert_sent_messages([
          {guest.pid, ":ChanServ!service@irc.test NOTICE #{guest.nick} :Access denied for \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "allows users with F to modify flags" do
      Memento.transaction!(fn ->
        manager = insert(:registered_nick, nickname: "Manager")
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: manager.account_name)
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        insert(:registered_channel_access, channel_name: channel.name, account_name: manager.account_name, flags: "VF")

        assert :ok = Flags.handle(user, ["FLAGS", channel.name, helper.nickname, "VA"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Flags for \x02#{helper.account_name}\x02 on \x02#{channel.name}\x02 are now \x02VA\x02.\r\n"}
        ])
      end)
    end

    test "rejects flag changes for the founder" do
      Memento.transaction!(fn ->
        founder_nick = insert(:registered_nick, nickname: "FounderNick", account_name: "founder")
        user = insert(:user, identified_as: "founder")
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Flags.handle(user, ["FLAGS", channel.name, founder_nick.nickname, "VA"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :The founder has implicit flags and cannot be changed with FLAGS.\r\n"}
        ])
      end)
    end
  end
end
