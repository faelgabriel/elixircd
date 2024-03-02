defmodule ElixIRCd.Command.WhoisTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Whois
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles WHOIS command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, identity: nil)
        message = %Message{command: "WHOIS", params: ["#anything"]}

        Whois.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles WHOIS command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHOIS", params: []}

        Whois.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} WHOIS :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles WHOIS command with invalid nick" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHOIS", params: ["invalid.nick"]}

        Whois.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 401 #{user.nick} invalid.nick :No such nick\r\n"},
          {user.socket, ":server.example.com 318 #{user.nick} invalid.nick :End of /WHOIS list.\r\n"}
        ])
      end)
    end

    test "handles WHOIS command with valid nick" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick")
        message = %Message{command: "WHOIS", params: ["target_nick"]}
        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel)

        Whois.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 311 #{user.nick} #{target_user.nick} username hostname * :realname\r\n"},
          {user.socket, ":server.example.com 319 #{user.nick} #{target_user.nick} :#{channel.name}\r\n"},
          {user.socket,
           ":server.example.com 312 #{user.nick} #{target_user.nick} ElixIRCd 0.1.0 :Elixir IRC daemon\r\n"},
          {user.socket, ":server.example.com 317 #{user.nick} #{target_user.nick} 0 :seconds idle, signon time\r\n"},
          {user.socket, ":server.example.com 318 #{user.nick} #{target_user.nick} :End of /WHOIS list.\r\n"}
        ])
      end)
    end

    test "handles WHOIS command with multiple valid and invalid nicks" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick")
        message = %Message{command: "WHOIS", params: ["invalid.nick", "target_nick", "invalid.nick2"]}

        Whois.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 401 #{user.nick} invalid.nick :No such nick\r\n"},
          {user.socket, ":server.example.com 318 #{user.nick} invalid.nick :End of /WHOIS list.\r\n"},
          {user.socket, ":server.example.com 311 #{user.nick} #{target_user.nick} username hostname * :realname\r\n"},
          {user.socket, ":server.example.com 319 #{user.nick} #{target_user.nick} :\r\n"},
          {user.socket,
           ":server.example.com 312 #{user.nick} #{target_user.nick} ElixIRCd 0.1.0 :Elixir IRC daemon\r\n"},
          {user.socket, ":server.example.com 317 #{user.nick} #{target_user.nick} 0 :seconds idle, signon time\r\n"},
          {user.socket, ":server.example.com 318 #{user.nick} #{target_user.nick} :End of /WHOIS list.\r\n"},
          {user.socket, ":server.example.com 401 #{user.nick} invalid.nick2 :No such nick\r\n"},
          {user.socket, ":server.example.com 318 #{user.nick} invalid.nick2 :End of /WHOIS list.\r\n"}
        ])
      end)
    end
  end
end
