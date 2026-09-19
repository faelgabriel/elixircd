defmodule ElixIRCd.Services.Nickserv.ListTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Nickserv.List
  alias ElixIRCd.Tables.RegisteredNick.Settings

  describe "handle/2" do
    test "lists public nicknames and filters private accounts" do
      Memento.transaction!(fn ->
        user = insert(:user)
        public_nick = insert(:registered_nick, nickname: "PublicNick")

        insert(:registered_nick,
          nickname: "PrivateNick",
          settings: Settings.new(%{private: true})
        )

        assert :ok = List.handle(user, ["LIST"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Registered nicknames:\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :  #{public_nick.nickname}\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :End of list.\r\n"}
        ])
      end)
    end

    test "shows private nicknames to their owner and displays aliases" do
      Memento.transaction!(fn ->
        primary =
          insert(:registered_nick,
            nickname: "PrimaryNick",
            settings: Settings.new(%{private: true, display: "AliasNick"})
          )

        insert(:registered_nick,
          nickname: "AliasNick",
          account_name: primary.account_name,
          password_hash: primary.password_hash,
          settings: primary.settings
        )

        user = insert(:user, identified_as: primary.account_name)

        assert :ok = List.handle(user, ["LIST", "*Nick"])

        assert_sent_message_contains(user.pid, ~r/PrimaryNick \(AliasNick\)/)
        assert_sent_message_contains(user.pid, ~r/  AliasNick\r?\n/)
        assert_sent_messages_count_containing(user.pid, ~r/NOTICE .*PrivateNick/, 0)
      end)
    end

    test "shows all private nicknames to IRC operators" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: [:o])
        private_nick = insert(:registered_nick, nickname: "PrivateNick", settings: Settings.new(%{private: true}))

        assert :ok = List.handle(user, ["LIST", "Private*"])

        assert_sent_message_contains(user.pid, ~r/  #{private_nick.nickname}/)
      end)
    end

    test "handles invalid parameter count and empty result" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = List.handle(user, ["LIST", "one", "two"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Too many parameters for \x02LIST\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02LIST [pattern]\x02\r\n"}
        ])

        assert :ok = List.handle(user, ["LIST", "does-not-exist"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :No registered nicknames matched your search.\r\n"}
        ])
      end)
    end

    test "keeps an alias visible when its canonical account record is missing" do
      Memento.transaction!(fn ->
        user = insert(:user)

        insert(:registered_nick,
          nickname: "OrphanAlias",
          account_name: "MissingAccount",
          settings: Settings.new()
        )

        assert :ok = List.handle(user, ["LIST", "Orphan*"])
        assert_sent_message_contains(user.pid, ~r/OrphanAlias/)
      end)
    end

    test "uses IRC case mapping and enforces the configured result and pattern limits" do
      services = Application.fetch_env!(:elixircd, :services)
      nickserv = Keyword.fetch!(services, :nickserv)
      limited_nickserv = Keyword.merge(nickserv, max_list_results: 1, max_list_pattern_length: 4)
      Application.put_env(:elixircd, :services, Keyword.put(services, :nickserv, limited_nickserv))

      try do
        Memento.transaction!(fn ->
          user = insert(:user)
          insert(:registered_nick, nickname: "Foo[")
          insert(:registered_nick, nickname: "Bar")

          assert :ok = List.handle(user, ["LIST", "foo{"])

          assert_sent_messages([
            {user.pid, ~r/Registered nicknames:/},
            {user.pid, ~r/:  Foo\[/},
            {user.pid, ~r/End of list/}
          ])

          assert :ok = List.handle(user, ["LIST", "*"])

          assert_sent_messages([
            {user.pid, ~r/Registered nicknames:/},
            {user.pid, ~r/:  /},
            {user.pid, ~r/End of list/}
          ])

          assert :ok = List.handle(user, ["LIST", "abcde"])
          assert_sent_messages([{user.pid, ~r/LIST pattern is too long/}])
        end)
      after
        Application.put_env(:elixircd, :services, services)
      end
    end
  end
end
