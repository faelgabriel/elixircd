defmodule ElixIRCd.Services.Chanserv.StatusTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Chanserv.Status

  describe "handle/2" do
    test "shows syntax when channel is missing" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "founder")

        assert :ok = Status.handle(user, ["STATUS"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02STATUS\x02.\r\n"},
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02STATUS <channel> [nickname]\x02\r\n"}
        ])
      end)
    end

    test "shows syntax when channel is missing for unidentified users" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Status.handle(user, ["STATUS"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02STATUS\x02.\r\n"},
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02STATUS <channel> [nickname]\x02\r\n"}
        ])
      end)
    end

    test "requires identification when no nickname is provided" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Status.handle(user, ["STATUS", "#testchannel"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You must be identified with NickServ or specify a nickname to use this command.\r\n"}
        ])
      end)
    end

    test "reports unknown channels for the current account" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "founder")

        assert :ok = Status.handle(user, ["STATUS", "#missing"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#missing\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "shows founder status" do
      Memento.transaction!(fn ->
        founder = insert(:registered_nick, nickname: "Founder", account_name: "founder")
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: "#testchannel", founder: founder.account_name)

        assert :ok = Status.handle(user, ["STATUS", "#testchannel"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Status for \x02#{founder.account_name}\x02 on \x02#testchannel\x02: level 5 (flags \x02VAFST\x02, founder)\r\n"}
        ])
      end)
    end

    test "shows explicit access status for a nickname" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: "#testchannel", founder: "founder")

        insert(:registered_channel_access,
          channel_name: "#testchannel",
          account_name: helper.account_name,
          flags: "VAF"
        )

        assert :ok = Status.handle(user, ["STATUS", "#testchannel", helper.nickname])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Status for \x02#{helper.account_name}\x02 on \x02#testchannel\x02: level 3 (flags \x02VAF\x02)\r\n"}
        ])
      end)
    end

    test "reports when an account has no access" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Status.handle(user, ["STATUS", "#testchannel", helper.nickname])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\x02#{helper.account_name}\x02 has no ChanServ access on \x02#testchannel\x02.\r\n"}
        ])
      end)
    end

    test "handles unknown nicknames and unknown channels" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "founder")
        founder = insert(:registered_nick, nickname: "FounderNick", account_name: "founder")

        assert :ok = Status.handle(user, ["STATUS", "#testchannel", "missing"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :The nickname \x02missing\x02 is neither registered nor identified.\r\n"}
        ])

        assert :ok = Status.handle(user, ["STATUS", "#missing", founder.nickname])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#missing\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "resolves online identified users without a registered nickname alias" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "founder")
        online_helper = insert(:user, nick: "LiveHelper", identified_as: "helper")
        insert(:registered_channel, name: "#testchannel", founder: "founder")

        insert(:registered_channel_access,
          channel_name: "#testchannel",
          account_name: "helper",
          flags: "VAF"
        )

        assert :ok = Status.handle(user, ["STATUS", "#testchannel", online_helper.nick])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Status for \x02helper\x02 on \x02#testchannel\x02: level 3 (flags \x02VAF\x02)\r\n"}
        ])
      end)
    end

    test "shows syntax for extra parameters" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "founder")

        assert :ok = Status.handle(user, ["STATUS", "#channel", "nick", "extra"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02STATUS <channel> [nickname]\x02\r\n"}
        ])
      end)
    end

    test "shows custom status levels for non-standard flag bundles" do
      Memento.transaction!(fn ->
        helper = insert(:registered_nick, nickname: "Helper")
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: "#testchannel", founder: "founder")

        insert(:registered_channel_access,
          channel_name: "#testchannel",
          account_name: helper.account_name,
          flags: "VF"
        )

        assert :ok = Status.handle(user, ["STATUS", "#testchannel", helper.nickname])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Status for \x02#{helper.account_name}\x02 on \x02#testchannel\x02: level custom (flags \x02VF\x02)\r\n"}
        ])
      end)
    end
  end
end
