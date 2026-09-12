defmodule ElixIRCd.Services.Nickserv.ListchansTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Nickserv.Listchans

  describe "handle/2" do
    test "lists channels where the account is founder or successor" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "account")
        insert(:registered_channel, name: "#founder", founder: "account")
        insert(:registered_channel, name: "#successor", founder: "other", successor: "account")

        assert :ok = Listchans.handle(user, ["LISTCHANS"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Registered channels for \x02account\x02:\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  #founder (founder)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  #successor (successor)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :End of list.\r\n"}
        ])
      end)
    end

    test "reports when the account is neither founder nor successor" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "account")

        assert :ok = Listchans.handle(user, ["LISTCHANS"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Your account is neither founder nor successor for any registered channel.\r\n"}
        ])
      end)
    end

    test "requires identification" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Listchans.handle(user, ["LISTCHANS"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You must identify to NickServ before using the LISTCHANS command.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Use \x02/msg NickServ IDENTIFY <password>\x02 to identify.\r\n"}
        ])
      end)
    end

    test "deduplicates channel where account is both founder and successor" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "account")
        insert(:registered_channel, name: "#mychan", founder: "account", successor: "account")

        assert :ok = Listchans.handle(user, ["LISTCHANS"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Registered channels for \x02account\x02:\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  #mychan (founder)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :End of list.\r\n"}
        ])
      end)
    end

    test "lists channels sorted alphabetically" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "account")
        insert(:registered_channel, name: "#zebra", founder: "account")
        insert(:registered_channel, name: "#alpha", founder: "account")
        insert(:registered_channel, name: "#middle", founder: "account")

        assert :ok = Listchans.handle(user, ["LISTCHANS"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Registered channels for \x02account\x02:\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  #alpha (founder)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  #middle (founder)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  #zebra (founder)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :End of list.\r\n"}
        ])
      end)
    end

    test "rejects extra parameters" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "account")

        assert :ok = Listchans.handle(user, ["LISTCHANS", "extra"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Too many parameters for \x02LISTCHANS\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02LISTCHANS\x02\r\n"}
        ])
      end)
    end
  end
end
