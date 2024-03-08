defmodule ElixIRCd.Command.ModeTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Command.Mode
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles MODE command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "MODE", params: ["#anything"]}

        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles MODE command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "MODE", params: []}

        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} MODE :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles MODE command with non-existing channel" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "MODE", params: ["#channel"]}
        Mode.handle(user, message)

        message = %Message{command: "MODE", params: ["#channel", "+t"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 403 #{user.nick} #channel :No such channel\r\n"},
          {user.socket, ":server.example.com 403 #{user.nick} #channel :No such channel\r\n"}
        ])
      end)
    end

    test "handles MODE command with existing channel and user is not in the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)

        message = %Message{command: "MODE", params: [channel.name]}
        Mode.handle(user, message)

        message = %Message{command: "MODE", params: [channel.name, "+t"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 442 #{user.nick} #{channel.name} :You're not on that channel\r\n"},
          {user.socket, ":server.example.com 442 #{user.nick} #{channel.name} :You're not on that channel\r\n"}
        ])
      end)
    end

    test "handles MODE command with channel and without mode parameter" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["t", "n", {"l", "10"}])
        insert(:user_channel, user: user, channel: channel)

        message = %Message{command: "MODE", params: [channel.name]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":#{user.identity} MODE #{channel.name} +tnl 10\r\n"}
        ])
      end)
    end

    test "handles MODE command with channel and with add modes" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["n", {"l", "10"}])
        insert(:user_channel, user: user, channel: channel)

        message = %Message{command: "MODE", params: [channel.name, "+t+s"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":#{user.identity} MODE #{channel.name} +ts\r\n"}
        ])
      end)
    end

    test "handles MODE command with channel and with remove modes" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["n", "t", "s", {"l", "10"}])
        insert(:user_channel, user: user, channel: channel)

        message = %Message{command: "MODE", params: [channel.name, "-t-s"]}
        Mode.handle(user, message)

        assert_sent_messages([
          {user.socket, ":#{user.identity} MODE #{channel.name} -ts\r\n"}
        ])
      end)
    end
  end
end
