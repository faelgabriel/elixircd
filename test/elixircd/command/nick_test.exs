defmodule ElixIRCd.Command.NickTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Helper, only: [get_user_mask: 1]
  import Mimic

  alias ElixIRCd.Command.Nick
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Handshake

  describe "handle/2" do
    test "handles NICK command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "NICK", params: []}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 461 #{user.nick} NICK :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles NICK command with invalid nick too long" do
      nick = "nick.too.long.nick.too.long.nick.too.long"

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "NICK", params: [nick]}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 432 * #{nick} :Nickname is unavailable: Nickname too long\r\n"}
        ])
      end)
    end

    test "handles NICK command with invalid nick with illegal characters" do
      nick = "invalid.nick"

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "NICK", params: [nick]}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 432 * #{nick} :Nickname is unavailable: Illegal characters\r\n"}
        ])
      end)
    end

    test "handles NICK command with valid nick already in use" do
      nick = "existing"
      insert(:user, nick: nick)

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "NICK", params: [nick]}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 433 #{user.nick} existing :Nickname is already in use\r\n"}
        ])
      end)
    end

    test "handles NICK command with valid nick for user registered" do
      nick = "new_nick"

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "NICK", params: [nick]}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([{user.pid, ":#{get_user_mask(user)} NICK #{nick}\r\n"}])
      end)
    end

    test "handles NICK command with valid nick for user not registered" do
      Handshake
      |> expect(:handle, fn _user -> :ok end)

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "NICK", params: ["new_nick"]}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles NICK command with valid nick passed in the trailing" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "NICK", params: [], trailing: "new_nick"}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([{user.pid, ":#{get_user_mask(user)} NICK new_nick\r\n"}])
      end)
    end

    test "handles NICK command with valid nick with user in a channel with other users" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)
        another_user = insert(:user)
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NICK", params: ["new_nick"]}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{get_user_mask(user)} NICK new_nick\r\n"},
          {another_user.pid, ":#{get_user_mask(user)} NICK new_nick\r\n"}
        ])
      end)
    end
  end
end
