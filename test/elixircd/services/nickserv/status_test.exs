defmodule ElixIRCd.Services.Nickserv.StatusTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Nickserv.Status

  describe "handle/2" do
    test "handles STATUS command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Status.handle(user, ["STATUS"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02STATUS\x02.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02STATUS <nickname> [nickname2 ...]\x02\r\n"}
        ])
      end)
    end

    test "returns STATUS 0 for unregistered nick" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Status.handle(user, ["STATUS", "UnregisteredNick"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :STATUS UnregisteredNick 0\r\n"}
        ])
      end)
    end

    test "returns STATUS 1 for registered nick that is not online" do
      Memento.transaction!(fn ->
        _registered_nick = insert(:registered_nick, nickname: "OfflineNick")
        user = insert(:user)

        assert :ok = Status.handle(user, ["STATUS", "OfflineNick"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :STATUS OfflineNick 1\r\n"}
        ])
      end)
    end

    test "returns STATUS 1 for registered nick that is online but not identified" do
      Memento.transaction!(fn ->
        _registered_nick = insert(:registered_nick, nickname: "OnlineButNotIdentified")
        _target_user = insert(:user, nick: "OnlineButNotIdentified", identified_as: nil)
        requester = insert(:user)

        assert :ok = Status.handle(requester, ["STATUS", "OnlineButNotIdentified"])

        assert_sent_messages([
          {requester.pid, ":NickServ!service@irc.test NOTICE #{requester.nick} :STATUS OnlineButNotIdentified 1\r\n"}
        ])
      end)
    end

    test "returns STATUS 2 for identified nick without ACCESS match or SASL" do
      Memento.transaction!(fn ->
        _registered_nick = insert(:registered_nick, nickname: "IdentifiedNoTrust")

        _target_user =
          insert(:user,
            nick: "IdentifiedNoTrust",
            identified_as: "IdentifiedNoTrust",
            sasl_authenticated: false
          )

        requester = insert(:user)

        assert :ok = Status.handle(requester, ["STATUS", "IdentifiedNoTrust"])

        assert_sent_messages([
          {requester.pid, ":NickServ!service@irc.test NOTICE #{requester.nick} :STATUS IdentifiedNoTrust 2\r\n"}
        ])
      end)
    end

    test "returns STATUS 3 for identified nick via SASL" do
      Memento.transaction!(fn ->
        _registered_nick = insert(:registered_nick, nickname: "SASLUser")

        _target_user =
          insert(:user,
            nick: "SASLUser",
            identified_as: "SASLUser",
            sasl_authenticated: true
          )

        requester = insert(:user)

        assert :ok = Status.handle(requester, ["STATUS", "SASLUser"])

        assert_sent_messages([
          {requester.pid, ":NickServ!service@irc.test NOTICE #{requester.nick} :STATUS SASLUser 3\r\n"}
        ])
      end)
    end

    test "returns STATUS 3 for identified nick with ACCESS match" do
      Memento.transaction!(fn ->
        _registered_nick = insert(:registered_nick, nickname: "TrustedUser")

        _target_user =
          insert(:user,
            nick: "TrustedUser",
            ident: "testident",
            hostname: "test.example.com",
            identified_as: "TrustedUser",
            sasl_authenticated: false,
            registered: true
          )

        # Add ACCESS entry matching the user's host
        insert(:nick_access, nickname: "TrustedUser", mask: "*@test.example.com")

        requester = insert(:user)

        assert :ok = Status.handle(requester, ["STATUS", "TrustedUser"])

        assert_sent_messages([
          {requester.pid, ":NickServ!service@irc.test NOTICE #{requester.nick} :STATUS TrustedUser 3\r\n"}
        ])
      end)
    end

    test "handles multiple nicknames in a single command" do
      Memento.transaction!(fn ->
        # Unregistered
        # Registered but offline
        _registered_offline = insert(:registered_nick, nickname: "OfflineUser")

        # Identified without trust
        _registered_identified = insert(:registered_nick, nickname: "IdentifiedUser")

        _identified_user =
          insert(:user,
            nick: "IdentifiedUser",
            identified_as: "IdentifiedUser",
            sasl_authenticated: false
          )

        # Identified with SASL
        _registered_sasl = insert(:registered_nick, nickname: "SASLUser")

        _sasl_user =
          insert(:user,
            nick: "SASLUser",
            identified_as: "SASLUser",
            sasl_authenticated: true
          )

        requester = insert(:user)

        assert :ok =
                 Status.handle(requester, [
                   "STATUS",
                   "UnregNick",
                   "OfflineUser",
                   "IdentifiedUser",
                   "SASLUser"
                 ])

        assert_sent_messages([
          {requester.pid, ":NickServ!service@irc.test NOTICE #{requester.nick} :STATUS UnregNick 0\r\n"},
          {requester.pid, ":NickServ!service@irc.test NOTICE #{requester.nick} :STATUS OfflineUser 1\r\n"},
          {requester.pid, ":NickServ!service@irc.test NOTICE #{requester.nick} :STATUS IdentifiedUser 2\r\n"},
          {requester.pid, ":NickServ!service@irc.test NOTICE #{requester.nick} :STATUS SASLUser 3\r\n"}
        ])
      end)
    end

    test "returns STATUS 3 when user matches ACCESS with wildcard ident" do
      Memento.transaction!(fn ->
        _registered_nick = insert(:registered_nick, nickname: "WildcardUser")

        _target_user =
          insert(:user,
            nick: "WildcardUser",
            ident: "anyident",
            hostname: "trusted.vpn",
            identified_as: "WildcardUser",
            sasl_authenticated: false,
            registered: true
          )

        # Add ACCESS entry with wildcard ident
        insert(:nick_access, nickname: "WildcardUser", mask: "*@trusted.vpn")

        requester = insert(:user)

        assert :ok = Status.handle(requester, ["STATUS", "WildcardUser"])

        assert_sent_messages([
          {requester.pid, ":NickServ!service@irc.test NOTICE #{requester.nick} :STATUS WildcardUser 3\r\n"}
        ])
      end)
    end

    test "returns STATUS 2 when user does not match ACCESS" do
      Memento.transaction!(fn ->
        _registered_nick = insert(:registered_nick, nickname: "NoAccessMatch")

        _target_user =
          insert(:user,
            nick: "NoAccessMatch",
            ident: "testident",
            hostname: "different.example.com",
            identified_as: "NoAccessMatch",
            sasl_authenticated: false,
            registered: true
          )

        # Add ACCESS entry that doesn't match
        insert(:nick_access, nickname: "NoAccessMatch", mask: "*@trusted.vpn")

        requester = insert(:user)

        assert :ok = Status.handle(requester, ["STATUS", "NoAccessMatch"])

        assert_sent_messages([
          {requester.pid, ":NickServ!service@irc.test NOTICE #{requester.nick} :STATUS NoAccessMatch 2\r\n"}
        ])
      end)
    end

    test "returns STATUS 1 for user identified to different account" do
      Memento.transaction!(fn ->
        _registered_nick_a = insert(:registered_nick, nickname: "AccountA")
        _registered_nick_b = insert(:registered_nick, nickname: "AccountB")

        # User is using nick AccountA but identified as AccountB
        _target_user =
          insert(:user,
            nick: "AccountA",
            identified_as: "AccountB"
          )

        requester = insert(:user)

        assert :ok = Status.handle(requester, ["STATUS", "AccountA"])

        assert_sent_messages([
          {requester.pid, ":NickServ!service@irc.test NOTICE #{requester.nick} :STATUS AccountA 1\r\n"}
        ])
      end)
    end

    test "returns STATUS 2 for grouped nick when user is identified to its canonical account" do
      Memento.transaction!(fn ->
        primary_nick = insert(:registered_nick, nickname: "PrimaryNick")
        _grouped_nick = insert(:registered_nick, nickname: "AliasNick", account_name: primary_nick.nickname)

        _target_user =
          insert(:user,
            nick: "AliasNick",
            identified_as: primary_nick.nickname,
            sasl_authenticated: false
          )

        requester = insert(:user)

        assert :ok = Status.handle(requester, ["STATUS", "AliasNick"])

        assert_sent_messages([
          {requester.pid, ":NickServ!service@irc.test NOTICE #{requester.nick} :STATUS AliasNick 2\r\n"}
        ])
      end)
    end
  end
end
