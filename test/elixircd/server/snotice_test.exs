defmodule ElixIRCd.Server.SnoticeTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Server.Snotice

  describe "broadcast/2" do
    test "sends notice only to operators with +s mode for all categories" do
      Memento.transaction!(fn ->
        oper_with_s = insert(:user, nick: "oper_s", modes: ["s", "o"])
        _user_with_s = insert(:user, nick: "user_s", modes: ["s"])
        _user_without_s = insert(:user, nick: "user_no_s", modes: [])

        assert :ok = Snotice.broadcast(:connect, "Test connection message")

        assert_sent_messages([
          {oper_with_s.pid, ":irc.test NOTICE :*** Connect: Test connection message\r\n"}
        ])
      end)
    end

    test "sends notice to multiple operators with +s mode" do
      Memento.transaction!(fn ->
        oper1 = insert(:user, nick: "oper1", modes: ["s", "o"])
        oper2 = insert(:user, nick: "oper2", modes: ["s", "o"])
        _user = insert(:user, nick: "user", modes: ["s"])

        assert :ok = Snotice.broadcast(:quit, "Test quit message")

        assert_sent_messages(
          [
            {oper1.pid, ":irc.test NOTICE :*** Quit: Test quit message\r\n"},
            {oper2.pid, ":irc.test NOTICE :*** Quit: Test quit message\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "sends operator-only notice only to operators with +s mode" do
      Memento.transaction!(fn ->
        oper_with_s = insert(:user, nick: "oper_s", modes: ["s", "o"])
        _user_with_s = insert(:user, nick: "user_s", modes: ["s"])
        _oper_without_s = insert(:user, nick: "oper_no_s", modes: ["o"])

        assert :ok = Snotice.broadcast(:oper, "Someone opered")

        assert_sent_messages([
          {oper_with_s.pid, ":irc.test NOTICE :*** Oper: Someone opered\r\n"}
        ])
      end)
    end

    test "sends kill notice only to operators with +s mode" do
      Memento.transaction!(fn ->
        oper_with_s = insert(:user, nick: "oper_s", modes: ["s", "o"])
        _user_with_s = insert(:user, nick: "user_s", modes: ["s"])

        assert :ok = Snotice.broadcast(:kill, "admin killed baduser (Spam)")

        assert_sent_messages([
          {oper_with_s.pid, ":irc.test NOTICE :*** Kill: admin killed baduser (Spam)\r\n"}
        ])
      end)
    end

    test "formats message with correct category prefix" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["s", "o"])

        Snotice.broadcast(:connect, "test")
        Snotice.broadcast(:quit, "test")
        Snotice.broadcast(:nick, "test")
        Snotice.broadcast(:flood, "test")
        Snotice.broadcast(:oper, "test")
        Snotice.broadcast(:kill, "test")

        assert_sent_messages([
          {user.pid, ":irc.test NOTICE :*** Connect: test\r\n"},
          {user.pid, ":irc.test NOTICE :*** Quit: test\r\n"},
          {user.pid, ":irc.test NOTICE :*** Nick: test\r\n"},
          {user.pid, ":irc.test NOTICE :*** Flood: test\r\n"},
          {user.pid, ":irc.test NOTICE :*** Oper: test\r\n"},
          {user.pid, ":irc.test NOTICE :*** Kill: test\r\n"}
        ])
      end)
    end

    test "returns :ok even when no operators have +s mode" do
      Memento.transaction!(fn ->
        insert(:user, modes: ["s"])
        insert(:user, modes: ["o"])

        assert :ok = Snotice.broadcast(:connect, "No one will receive this")
      end)
    end

    test "does not send to unregistered operators" do
      Memento.transaction!(fn ->
        _unregistered = insert(:user, registered: false, modes: ["s", "o"])
        registered = insert(:user, nick: "registered", modes: ["s", "o"])

        assert :ok = Snotice.broadcast(:connect, "Test message")

        assert_sent_messages([
          {registered.pid, ":irc.test NOTICE :*** Connect: Test message\r\n"}
        ])
      end)
    end
  end

  describe "format_user_info/1" do
    test "formats user info with nick, ident, hostname and IP" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "testnick", ident: "testident", hostname: "test.host", ip_address: {127, 0, 0, 1})

        assert "testnick!testident@test.host [127.0.0.1]" == Snotice.format_user_info(user)
      end)
    end
  end
end
