defmodule ElixIRCd.Services.Nickserv.AlistTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.NickAccesses
  alias ElixIRCd.Services.Nickserv.Alist

  describe "handle/2 - no accounts recognized" do
    test "shows empty result when user has no accounts" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Alist.handle(user, ["ALIST"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :You are not recognized for any accounts.\r\n"}
        ])
      end)
    end

    test "shows empty result when user is unregistered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, identified_as: nil)

        assert :ok = Alist.handle(user, ["ALIST"])

        # Unregistered users show * as their nick in NOTICE messages
        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE * :You are not recognized for any accounts.\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - authenticated account" do
    test "shows currently authenticated account" do
      Memento.transaction!(fn ->
        _registered_nick = insert(:registered_nick, nickname: "TestUser")
        user = insert(:user, identified_as: "TestUser", sasl_authenticated: false)

        assert :ok = Alist.handle(user, ["ALIST"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Accounts you are recognized for:\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  TestUser (authenticated)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :End of list.\r\n"}
        ])
      end)
    end

    test "shows SASL authenticated account" do
      Memento.transaction!(fn ->
        _registered_nick = insert(:registered_nick, nickname: "TestUser")
        user = insert(:user, identified_as: "TestUser", sasl_authenticated: true)

        assert :ok = Alist.handle(user, ["ALIST"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Accounts you are recognized for:\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  TestUser (via SASL)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :End of list.\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - ACCESS matches" do
    test "shows accounts with matching ACCESS masks" do
      Memento.transaction!(fn ->
        _registered_nick = insert(:registered_nick, nickname: "Account1")
        user = insert(:user, identified_as: nil, ident: "user", hostname: "example.com")

        NickAccesses.create(%{
          nickname: "Account1",
          mask: "*@example.com"
        })

        assert :ok = Alist.handle(user, ["ALIST"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Accounts you are recognized for:\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  Account1 (via access)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :End of list.\r\n"}
        ])
      end)
    end

    test "shows multiple accounts with different ACCESS masks" do
      Memento.transaction!(fn ->
        _registered_nick1 = insert(:registered_nick, nickname: "Account1")
        _registered_nick2 = insert(:registered_nick, nickname: "Account2")
        _registered_nick3 = insert(:registered_nick, nickname: "Account3")
        user = insert(:user, identified_as: nil, ident: "user", hostname: "example.com")

        NickAccesses.create(%{
          nickname: "Account1",
          mask: "*@example.com"
        })

        NickAccesses.create(%{
          nickname: "Account2",
          mask: "user@*.com"
        })

        NickAccesses.create(%{
          nickname: "Account3",
          mask: "*@different.org"
        })

        assert :ok = Alist.handle(user, ["ALIST"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Accounts you are recognized for:\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  Account1 (via access)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  Account2 (via access)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :End of list.\r\n"}
        ])
      end)
    end

    test "handles wildcard matches correctly" do
      Memento.transaction!(fn ->
        _registered_nick = insert(:registered_nick, nickname: "WildcardAccount")
        user = insert(:user, identified_as: nil, ident: "testuser", hostname: "sub.example.com")

        NickAccesses.create(%{
          nickname: "WildcardAccount",
          mask: "*@*.example.com"
        })

        assert :ok = Alist.handle(user, ["ALIST"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Accounts you are recognized for:\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  WildcardAccount (via access)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :End of list.\r\n"}
        ])
      end)
    end

    test "does not show accounts with non-matching ACCESS masks" do
      Memento.transaction!(fn ->
        _registered_nick = insert(:registered_nick, nickname: "OtherAccount")
        user = insert(:user, identified_as: nil, ident: "user", hostname: "example.com")

        NickAccesses.create(%{
          nickname: "OtherAccount",
          mask: "*@different.org"
        })

        assert :ok = Alist.handle(user, ["ALIST"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :You are not recognized for any accounts.\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - combined sources" do
    test "shows authenticated account plus ACCESS matches" do
      Memento.transaction!(fn ->
        _registered_nick1 = insert(:registered_nick, nickname: "MainAccount")
        _registered_nick2 = insert(:registered_nick, nickname: "SecondAccount")
        user = insert(:user, identified_as: "MainAccount", ident: "user", hostname: "example.com")

        NickAccesses.create(%{
          nickname: "SecondAccount",
          mask: "*@example.com"
        })

        assert :ok = Alist.handle(user, ["ALIST"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Accounts you are recognized for:\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  MainAccount (authenticated)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  SecondAccount (via access)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :End of list.\r\n"}
        ])
      end)
    end

    test "removes duplicates when same account from multiple sources" do
      Memento.transaction!(fn ->
        _registered_nick = insert(:registered_nick, nickname: "MyAccount")
        user = insert(:user, identified_as: "MyAccount", ident: "user", hostname: "example.com")

        NickAccesses.create(%{
          nickname: "MyAccount",
          mask: "*@example.com"
        })

        assert :ok = Alist.handle(user, ["ALIST"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Accounts you are recognized for:\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  MyAccount (authenticated)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :End of list.\r\n"}
        ])
      end)
    end

    test "ignores grouped aliases and lists only the canonical account once" do
      Memento.transaction!(fn ->
        primary_nick = insert(:registered_nick, nickname: "PrimaryNick")
        _alias_nick = insert(:registered_nick, nickname: "AliasNick", account_name: primary_nick.nickname)

        user = insert(:user, identified_as: nil, ident: "user", hostname: "example.com")

        NickAccesses.create(%{
          nickname: primary_nick.nickname,
          mask: "*@example.com"
        })

        assert :ok = Alist.handle(user, ["ALIST"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Accounts you are recognized for:\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  PrimaryNick (via access)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :End of list.\r\n"}
        ])
      end)
    end

    test "handles case-insensitive duplicate removal" do
      Memento.transaction!(fn ->
        _registered_nick = insert(:registered_nick, nickname: "TestAccount")
        user = insert(:user, identified_as: "testaccount", ident: "user", hostname: "example.com")

        NickAccesses.create(%{
          nickname: "TestAccount",
          mask: "*@example.com"
        })

        assert :ok = Alist.handle(user, ["ALIST"])

        # Should show only one entry even though case differs
        # The account will show from identified_as, not from ACCESS (because of deduplication)
        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Accounts you are recognized for:\r\n"},
          {user.pid, ~r/(testaccount|TestAccount)/},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :End of list.\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - sorting" do
    test "sorts accounts alphabetically case-insensitively" do
      Memento.transaction!(fn ->
        _registered_nick1 = insert(:registered_nick, nickname: "Zebra")
        _registered_nick2 = insert(:registered_nick, nickname: "apple")
        _registered_nick3 = insert(:registered_nick, nickname: "BANANA")
        user = insert(:user, identified_as: nil, ident: "user", hostname: "example.com")

        NickAccesses.create(%{
          nickname: "Zebra",
          mask: "*@example.com"
        })

        NickAccesses.create(%{
          nickname: "apple",
          mask: "*@example.com"
        })

        NickAccesses.create(%{
          nickname: "BANANA",
          mask: "*@example.com"
        })

        assert :ok = Alist.handle(user, ["ALIST"])

        # Verify the accounts are in sorted order
        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Accounts you are recognized for:\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  apple (via access)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  BANANA (via access)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  Zebra (via access)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :End of list.\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - specific ident matches" do
    test "matches specific ident in ACCESS mask" do
      Memento.transaction!(fn ->
        _registered_nick = insert(:registered_nick, nickname: "SpecificUser")
        user = insert(:user, identified_as: nil, ident: "john", hostname: "example.com")

        NickAccesses.create(%{
          nickname: "SpecificUser",
          mask: "john@example.com"
        })

        assert :ok = Alist.handle(user, ["ALIST"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Accounts you are recognized for:\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  SpecificUser (via access)\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :End of list.\r\n"}
        ])
      end)
    end

    test "does not match different ident" do
      Memento.transaction!(fn ->
        _registered_nick = insert(:registered_nick, nickname: "SpecificUser")
        user = insert(:user, identified_as: nil, ident: "jane", hostname: "example.com")

        NickAccesses.create(%{
          nickname: "SpecificUser",
          mask: "john@example.com"
        })

        assert :ok = Alist.handle(user, ["ALIST"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :You are not recognized for any accounts.\r\n"}
        ])
      end)
    end
  end
end
