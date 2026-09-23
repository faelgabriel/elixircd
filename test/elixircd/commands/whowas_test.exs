defmodule ElixIRCd.Commands.WhowasTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Whowas
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles WHOWAS command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "WHOWAS", params: ["#anything"]}

        assert :ok = Whowas.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles WHOWAS command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHOWAS", params: []}

        assert :ok = Whowas.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} WHOWAS :Not enough parameters\r\n"}
        ])
      end)
    end

    test "can use the RFC 1459 parameterless error sequence explicitly" do
      original = Application.fetch_env!(:elixircd, :compatibility)
      on_exit(fn -> Application.put_env(:elixircd, :compatibility, original) end)
      Application.put_env(:elixircd, :compatibility, Keyword.put(original, :rfc1459_whowas_errors, true))

      Memento.transaction!(fn ->
        user = insert(:user)
        assert :ok = Whowas.handle(user, %Message{command: "WHOWAS", params: []})

        assert_sent_messages([
          {user.pid, ":irc.test 431 #{user.nick} :No nickname given\r\n"},
          {user.pid, ":irc.test 369 #{user.nick} * :End of WHOWAS list\r\n"}
        ])
      end)
    end

    test "handles WHOWAS command with inexistent target nick" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHOWAS", params: ["inexistent"]}

        assert :ok = Whowas.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 406 #{user.nick} inexistent :There was no such nickname\r\n"},
          {user.pid, ":irc.test 369 #{user.nick} inexistent :End of WHOWAS list\r\n"}
        ])
      end)
    end

    test "handles WHOWAS command with target nick" do
      Memento.transaction!(fn ->
        historical_user1 = insert(:historical_user, nick: "nick")
        historical_user2 = insert(:historical_user, nick: "nick")
        user = insert(:user)
        message = %Message{command: "WHOWAS", params: ["nick"]}

        assert :ok = Whowas.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 314 #{user.nick} #{historical_user1.nick} #{historical_user1.ident} #{historical_user1.hostname} * :#{historical_user1.realname}\r\n"},
          {user.pid,
           ~r/^:irc\.test 312 #{user.nick} #{historical_user1.nick} irc.test :\w+ \w+ \d+ \d+ -- \d+:\d+:\d+ UTC\r\n/},
          {user.pid,
           ":irc.test 314 #{user.nick} #{historical_user2.nick} #{historical_user2.ident} #{historical_user2.hostname} * :#{historical_user2.realname}\r\n"},
          {user.pid,
           ~r/^:irc\.test 312 #{user.nick} #{historical_user2.nick} irc.test :\w+ \w+ \d+ \d+ -- \d+:\d+:\d+ UTC\r\n/},
          {user.pid, ":irc.test 369 #{user.nick} nick :End of WHOWAS list\r\n"}
        ])
      end)
    end

    test "handles WHOWAS command with target nick and max replies" do
      Memento.transaction!(fn ->
        _older = insert(:historical_user, nick: "nick")
        historical_user1 = insert(:historical_user, nick: "nick")
        user = insert(:user)
        message = %Message{command: "WHOWAS", params: ["nick", "1"]}

        assert :ok = Whowas.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 314 #{user.nick} #{historical_user1.nick} #{historical_user1.ident} #{historical_user1.hostname} * :#{historical_user1.realname}\r\n"},
          {user.pid,
           ~r/^:irc\.test 312 #{user.nick} #{historical_user1.nick} irc.test :\w+ \w+ \d+ \d+ -- \d+:\d+:\d+ UTC\r\n/},
          {user.pid, ":irc.test 369 #{user.nick} nick :End of WHOWAS list\r\n"}
        ])
      end)
    end

    test "handles WHOWAS command with target nick and invalid max replies number" do
      Memento.transaction!(fn ->
        historical_user1 = insert(:historical_user, nick: "nick")
        user = insert(:user)
        message = %Message{command: "WHOWAS", params: ["nick", "invalid"]}

        assert :ok = Whowas.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 314 #{user.nick} #{historical_user1.nick} #{historical_user1.ident} #{historical_user1.hostname} * :#{historical_user1.realname}\r\n"},
          {user.pid,
           ~r/^:irc\.test 312 #{user.nick} #{historical_user1.nick} irc.test :\w+ \w+ \d+ \d+ -- \d+:\d+:\d+ UTC\r\n/},
          {user.pid, ":irc.test 369 #{user.nick} nick :End of WHOWAS list\r\n"}
        ])
      end)
    end

    test "matches wildcard nicknames and terminates with the resolved nickname" do
      Memento.transaction!(fn ->
        historical_user = insert(:historical_user, nick: "NickTwo")
        user = insert(:user)

        assert :ok = Whowas.handle(user, %Message{command: "WHOWAS", params: ["*two"]})

        assert_sent_message_contains(user.pid, ~r/ 314 #{user.nick} NickTwo /)
        assert_sent_message_contains(user.pid, ":irc.test 369 #{user.nick} NickTwo :End of WHOWAS list\r\n")
        assert_sent_messages_amount(user.pid, 3)
        assert historical_user.nick == "NickTwo"
      end)
    end
  end
end
