defmodule ElixIRCd.Command.UserhostTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Helper, only: [get_user_mask: 1]

  alias ElixIRCd.Command.Userhost
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles USERHOST command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "USERHOST", params: ["#anything"]}

        assert :ok = Userhost.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles USERHOST command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "USERHOST", params: []}

        assert :ok = Userhost.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 461 #{user.nick} USERHOST :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles USERHOST command with invalid nick" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "USERHOST", params: ["invalid.nick"]}

        assert :ok = Userhost.handle(user, message)

        assert_sent_messages([{user.socket, ":server.example.com 302 #{user.nick} :\r\n"}])
      end)
    end

    test "handles USERHOST command with valid nick" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick")
        message = %Message{command: "USERHOST", params: ["target_nick"]}

        assert :ok = Userhost.handle(user, message)

        assert_sent_messages([
          {user.socket, ":server.example.com 302 #{user.nick} :#{target_user.nick}=#{get_user_mask(target_user)}\r\n"}
        ])
      end)
    end

    test "handles USERHOST command with multiple valid and invalid nicks" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick")
        target_user2 = insert(:user, nick: "target_nick2")
        message = %Message{command: "USERHOST", params: ["target_nick", "invalid.nick", "target_nick2"]}

        assert :ok = Userhost.handle(user, message)

        assert_sent_messages([
          {user.socket,
           ":server.example.com 302 #{user.nick} :#{target_user.nick}=#{get_user_mask(target_user)} #{target_user2.nick}=#{get_user_mask(target_user2)}\r\n"}
        ])
      end)
    end
  end
end
