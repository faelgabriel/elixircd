defmodule ElixIRCd.Services.Chanserv.AlistTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Chanserv.Alist

  describe "handle/2" do
    test "requires identification when no nickname is provided" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Alist.handle(user, ["ALIST"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You must be identified with NickServ to use this command.\r\n"}
        ])
      end)
    end

    test "accepts nickname lookups even when the caller is not identified" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: nil)
        insert(:registered_channel_access, channel_name: "#staff", account_name: helper.account_name, flags: "VA")

        assert :ok = Alist.handle(user, ["ALIST", helper.nickname])

        assert_sent_message_contains(
          user.pid,
          ~r/ChanServ.*NOTICE.*ChanServ access list for \x02#{helper.account_name}\x02:/
        )
      end)
    end

    test "lists founder and explicit channel access entries" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: helper.account_name)

        insert(:registered_channel, name: "#founder", founder: helper.account_name)
        insert(:registered_channel_access, channel_name: "#staff", account_name: helper.account_name, flags: "VAF")

        assert :ok = Alist.handle(user, ["ALIST"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :ChanServ access list for \x02#{helper.account_name}\x02:\r\n"},
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :1. \x02#founder\x02 level 5 (flags \x02VAFST\x02, founder)\r\n"},
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :2. \x02#staff\x02 level 3 (flags \x02VAF\x02)\r\n"},
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :End of ALIST.\r\n"}
        ])
      end)
    end

    test "allows looking up another registered nickname" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: "founder")

        insert(:registered_channel_access, channel_name: "#staff", account_name: helper.account_name, flags: "VA")

        assert :ok = Alist.handle(user, ["ALIST", helper.nickname])

        assert_sent_message_contains(
          user.pid,
          ~r/ChanServ.*NOTICE.*ChanServ access list for \x02#{helper.account_name}\x02:/
        )
      end)
    end

    test "handles accounts with no channel access entries" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: "founder")

        assert :ok = Alist.handle(user, ["ALIST", helper.nickname])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :No ChanServ access entries were found for \x02#{helper.account_name}\x02.\r\n"}
        ])
      end)
    end

    test "rejects unknown nicknames" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "founder")

        assert :ok = Alist.handle(user, ["ALIST", "missing"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :The nickname \x02missing\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "shows syntax for extra parameters" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "founder")

        assert :ok = Alist.handle(user, ["ALIST", "one", "two"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02ALIST [nickname]\x02\r\n"}
        ])
      end)
    end

    test "shows custom levels for non-standard flag bundles" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: helper.account_name)

        insert(:registered_channel_access, channel_name: "#staff", account_name: helper.account_name, flags: "VF")

        assert :ok = Alist.handle(user, ["ALIST"])

        assert_sent_message_contains(
          user.pid,
          ~r/ChanServ.*NOTICE.*#staff.*level custom.*flags \x02VF\x02/
        )
      end)
    end
  end
end
