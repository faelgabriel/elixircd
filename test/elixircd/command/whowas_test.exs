defmodule ElixIRCd.Command.WhowasTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Whowas
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles WHOWAS command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "WHOWAS", params: ["#anything"]}

        Whowas.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles WHOWAS command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHOWAS", params: []}

        Whowas.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} WHOWAS :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles WHOWAS command with inexistent target nick" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHOWAS", params: ["inexistent"]}

        Whowas.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 406 #{user.nick} inexistent :There was no such nickname\r\n"},
          {user.socket, ":server.example.com 369 #{user.nick} inexistent :End of WHOWAS list\r\n"}
        ])
      end)
    end

    test "handles WHOWAS command with target nick" do
      Memento.transaction!(fn ->
        historical_user1 = insert(:historical_user, nick: "nick")
        historical_user2 = insert(:historical_user, nick: "nick")
        user = insert(:user)
        message = %Message{command: "WHOWAS", params: ["nick"]}

        Whowas.handle(user, message)

        assert_sent_messages([
          {user.socket,
           ":server.example.com 314 #{user.nick} #{historical_user1.nick} #{historical_user1.username} #{historical_user1.hostname} #{historical_user1.realname}\r\n"},
          {user.socket,
           ~r/^:server\.example\.com 312 #{user.nick} #{historical_user1.nick} server.example.com \w+ \w+ \d+ \d+ -- \d+:\d+:\d+ UTC\r\n/},
          {user.socket,
           ":server.example.com 314 #{user.nick} #{historical_user2.nick} #{historical_user2.username} #{historical_user2.hostname} #{historical_user2.realname}\r\n"},
          {user.socket,
           ~r/^:server\.example\.com 312 #{user.nick} #{historical_user2.nick} server.example.com \w+ \w+ \d+ \d+ -- \d+:\d+:\d+ UTC\r\n/},
          {user.socket, ":server.example.com 369 #{user.nick} nick :End of WHOWAS list\r\n"}
        ])
      end)
    end

    test "handles WHOWAS command with target nick and max replies" do
      Memento.transaction!(fn ->
        historical_user1 = insert(:historical_user, nick: "nick")
        _historical_user2 = insert(:historical_user, nick: "nick")
        user = insert(:user)
        message = %Message{command: "WHOWAS", params: ["nick", "1"]}

        Whowas.handle(user, message)

        assert_sent_messages([
          {user.socket,
           ":server.example.com 314 #{user.nick} #{historical_user1.nick} #{historical_user1.username} #{historical_user1.hostname} #{historical_user1.realname}\r\n"},
          {user.socket,
           ~r/^:server\.example\.com 312 #{user.nick} #{historical_user1.nick} server.example.com \w+ \w+ \d+ \d+ -- \d+:\d+:\d+ UTC\r\n/},
          {user.socket, ":server.example.com 369 #{user.nick} nick :End of WHOWAS list\r\n"}
        ])
      end)
    end

    test "handles WHOWAS command with target nick and invalid max replies number" do
      Memento.transaction!(fn ->
        historical_user1 = insert(:historical_user, nick: "nick")
        user = insert(:user)
        message = %Message{command: "WHOWAS", params: ["nick", "invalid"]}

        Whowas.handle(user, message)

        assert_sent_messages([
          {user.socket,
           ":server.example.com 314 #{user.nick} #{historical_user1.nick} #{historical_user1.username} #{historical_user1.hostname} #{historical_user1.realname}\r\n"},
          {user.socket,
           ~r/^:server\.example\.com 312 #{user.nick} #{historical_user1.nick} server.example.com \w+ \w+ \d+ \d+ -- \d+:\d+:\d+ UTC\r\n/},
          {user.socket, ":server.example.com 369 #{user.nick} nick :End of WHOWAS list\r\n"}
        ])
      end)
    end
  end
end
