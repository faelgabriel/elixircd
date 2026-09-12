defmodule ElixIRCd.Services.Chanserv.AccessTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Services.Chanserv.Access

  describe "handle/2" do
    test "requires the user to be identified" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Access.handle(user, ["ACCESS", "#channel", "LIST"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You must be identified with NickServ to use this command.\r\n"}
        ])
      end)
    end

    test "shows syntax with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "founder")

        assert :ok = Access.handle(user, ["ACCESS"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02ACCESS\x02.\r\n"},
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02ACCESS <channel> {ADD|DEL|LIST|CLEAR} [nickname] [level]\x02\r\n"}
        ])
      end)
    end

    test "rejects non-registered channels" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "founder")

        assert :ok = Access.handle(user, ["ACCESS", "#missing", "LIST"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#missing\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "adds and lists access entries" do
      Memento.transaction!(fn ->
        founder = "founder"
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: founder)
        channel = insert(:registered_channel, name: "#testchannel", founder: founder)

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "ADD", helper.nickname, "3"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Access for \x02#{helper.account_name}\x02 on \x02#{channel.name}\x02 is now level \x023\x02 (flags \x02VAF\x02).\r\n"}
        ])

        assert %{helper.account_name => "VAF"} == RegisteredChannelAccesses.get_flags_map_by_channel_name(channel.name)

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "LIST"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Access list for \x02#{channel.name}\x02:\r\n"},
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Founder: \x02#{founder}\x02 (level 5, flags \x02VAFST\x02)\r\n"},
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :1. \x02#{helper.account_name}\x02 level 3 (flags \x02VAF\x02)\r\n"},
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :End of access list.\r\n"}
        ])
      end)
    end

    test "allows users with access management flags to modify the access list" do
      Memento.transaction!(fn ->
        founder = "founder"
        manager = insert(:registered_nick, nickname: "Manager")
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: manager.account_name)

        channel =
          insert(:registered_channel,
            name: "#testchannel",
            founder: founder
          )

        insert(:registered_channel_access, channel_name: channel.name, account_name: manager.account_name, flags: "VA")

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "ADD", helper.nickname, "2"])

        flags_map = RegisteredChannelAccesses.get_flags_map_by_channel_name(channel.name)

        assert flags_map[manager.account_name] == "VA"
        assert flags_map[helper.account_name] == "VA"
      end)
    end

    test "rejects invalid levels" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: "founder")
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "ADD", helper.nickname, "8"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Invalid access level. Supported levels are \x021\x02 through \x025\x02.\r\n"}
        ])
      end)
    end

    test "handles empty lists, unknown subcommands and syntax errors" do
      Memento.transaction!(fn ->
        founder_nick = insert(:registered_nick, nickname: "FounderNick", account_name: "founder")
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: "founder")
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "LIST"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :The access list for \x02#{channel.name}\x02 is empty.\r\n"}
        ])

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "CLEAR"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :The access list for \x02#{channel.name}\x02 is already empty.\r\n"}
        ])

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "BOGUS"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Unknown ACCESS subcommand: \x02BOGUS\x02\r\n"},
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02ACCESS <channel> {ADD|DEL|LIST|CLEAR} [nickname] [level]\x02\r\n"}
        ])

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "ADD", founder_nick.nickname, "1"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :The founder \x02founder\x02 has implicit access and cannot be changed with ACCESS.\r\n"}
        ])

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "ADD", "missing", "1"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :The nickname \x02missing\x02 is not registered.\r\n"}
        ])

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "DEL", founder_nick.nickname])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :The founder \x02founder\x02 has implicit access and cannot be changed with ACCESS.\r\n"}
        ])

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "ADD", "missing"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02ACCESS <channel> ADD <nickname> <level>\x02\r\n"}
        ])

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "DEL"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02ACCESS <channel> DEL <nickname>\x02\r\n"}
        ])

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "ADD", helper.nickname, "abc"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Invalid access level. Supported levels are \x021\x02 through \x025\x02.\r\n"}
        ])
      end)
    end

    test "deletes and clears access entries" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        staff = insert(:registered_nick, nickname: "Staff")
        user = insert(:user, identified_as: "founder")

        channel =
          insert(:registered_channel,
            name: "#testchannel",
            founder: "founder"
          )

        insert(:registered_channel_access, channel_name: channel.name, account_name: helper.account_name, flags: "VAF")
        insert(:registered_channel_access, channel_name: channel.name, account_name: staff.account_name, flags: "VA")

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "DEL", helper.nickname])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Removed \x02#{helper.account_name}\x02 from the access list for \x02#{channel.name}\x02.\r\n"}
        ])

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "CLEAR"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Cleared \x021\x02 access entry for \x02#{channel.name}\x02.\r\n"}
        ])

        assert %{} == RegisteredChannelAccesses.get_flags_map_by_channel_name(channel.name)
      end)
    end

    test "reports existing and missing entries during add and delete" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: "founder")
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        insert(:registered_channel_access, channel_name: channel.name, account_name: helper.account_name, flags: "V")

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "ADD", helper.nickname, "1"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\x02#{helper.account_name}\x02 already has access level \x021\x02 on \x02#{channel.name}\x02.\r\n"}
        ])

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "DEL", helper.nickname])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Removed \x02#{helper.account_name}\x02 from the access list for \x02#{channel.name}\x02.\r\n"}
        ])

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "DEL", helper.nickname])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\x02#{helper.account_name}\x02 is not in the access list for \x02#{channel.name}\x02.\r\n"}
        ])

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "DEL", "missing"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :The nickname \x02missing\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "rejects access list changes from users without permission" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: "visitor")
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "ADD", helper.nickname, "1"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Access denied for \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "rejects access list viewing from users without permission" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "visitor")
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "LIST"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Access denied for \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "lists custom flag bundles as custom levels" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: "founder")
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        insert(:registered_channel_access, channel_name: channel.name, account_name: helper.account_name, flags: "VF")

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "LIST"])

        assert_sent_message_contains(
          user.pid,
          ~r/ChanServ.*NOTICE.*#{helper.account_name}.*level custom.*flags \x02VF\x02/
        )
      end)
    end

    test "clears multiple access entries using the pluralized response" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        staff = insert(:registered_nick, nickname: "Staff")
        user = insert(:user, identified_as: "founder")
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        insert(:registered_channel_access, channel_name: channel.name, account_name: helper.account_name, flags: "VAF")
        insert(:registered_channel_access, channel_name: channel.name, account_name: staff.account_name, flags: "VA")

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "CLEAR"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Cleared \x022\x02 access entries for \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "denies granting an access level above the manager's own flags" do
      Memento.transaction!(fn ->
        manager = insert(:registered_nick, nickname: "Manager")
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: manager.account_name)
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        insert(:registered_channel_access, channel_name: channel.name, account_name: manager.account_name, flags: "VA")

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "ADD", helper.nickname, "4"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You cannot grant access level \x024\x02 to \x02#{helper.account_name}\x02 on \x02#{channel.name}\x02.\r\n"}
        ])

        refute Map.has_key?(RegisteredChannelAccesses.get_flags_map_by_channel_name(channel.name), helper.account_name)
      end)
    end

    test "only the founder can grant access level 5" do
      Memento.transaction!(fn ->
        manager = insert(:registered_nick, nickname: "Manager")
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: manager.account_name)
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        insert(:registered_channel_access,
          channel_name: channel.name,
          account_name: manager.account_name,
          flags: "VAFS"
        )

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "ADD", helper.nickname, "5"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Only the founder can grant access level \x025\x02 on \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "denies deleting access entries that outrank the manager" do
      Memento.transaction!(fn ->
        manager = insert(:registered_nick, nickname: "Manager")
        senior = insert(:registered_nick, nickname: "Senior")
        user = insert(:user, identified_as: manager.account_name)
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        insert(:registered_channel_access, channel_name: channel.name, account_name: manager.account_name, flags: "VA")
        insert(:registered_channel_access, channel_name: channel.name, account_name: senior.account_name, flags: "VAFS")

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "DEL", senior.nickname])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You cannot remove \x02#{senior.account_name}\x02 from the access list for \x02#{channel.name}\x02.\r\n"}
        ])

        assert %{"Manager" => "VA", "Senior" => "VAFS"} ==
                 RegisteredChannelAccesses.get_flags_map_by_channel_name(channel.name)
      end)
    end

    test "keeps outranking entries on ACCESS CLEAR" do
      Memento.transaction!(fn ->
        junior = insert(:registered_nick, nickname: "Junior")
        senior = insert(:registered_nick, nickname: "Senior")
        user = insert(:user, identified_as: "Manager")
        channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        insert(:registered_channel_access, channel_name: channel.name, account_name: "Manager", flags: "VAF")
        insert(:registered_channel_access, channel_name: channel.name, account_name: junior.account_name, flags: "V")
        insert(:registered_channel_access, channel_name: channel.name, account_name: senior.account_name, flags: "VAFS")

        assert :ok = Access.handle(user, ["ACCESS", channel.name, "CLEAR"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Cleared \x022\x02 access entries for \x02#{channel.name}\x02 (1 kept: insufficient access).\r\n"}
        ])

        assert %{"Senior" => "VAFS"} == RegisteredChannelAccesses.get_flags_map_by_channel_name(channel.name)
      end)
    end
  end

  test "possessing flags alone does not authorize delegation" do
    Memento.transaction!(fn ->
      insert(:registered_nick, nickname: "Target")
      insert(:registered_nick, nickname: "Actor")
      user = insert(:user, identified_as: "Actor")
      insert(:registered_channel, name: "#delegation", founder: "Founder")
      insert(:registered_channel_access, channel_name: "#delegation", account_name: "Actor", flags: "V")
      Access.handle(user, ["ACCESS", "#delegation", "ADD", "Target", "1"])
      assert_sent_message_contains(user.pid, ~r/Access denied/)
      assert RegisteredChannelAccesses.get_by_channel_name("#delegation") |> length() == 1
    end)
  end
end
