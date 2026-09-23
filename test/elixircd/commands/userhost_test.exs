defmodule ElixIRCd.Commands.UserhostTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Userhost
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles USERHOST command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "USERHOST", params: ["#anything"]}

        assert :ok = Userhost.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles USERHOST command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "USERHOST", params: []}

        assert :ok = Userhost.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} USERHOST :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles USERHOST command with invalid nick" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "USERHOST", params: ["invalid.nick"]}

        assert :ok = Userhost.handle(user, message)

        assert_sent_messages([{user.pid, ":irc.test 302 #{user.nick} :\r\n"}])
      end)
    end

    test "handles USERHOST command with valid nick" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick")
        message = %Message{command: "USERHOST", params: ["target_nick"]}

        assert :ok = Userhost.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 302 #{user.nick} :#{target_user.nick}=+#{target_user.ident}@#{target_user.hostname}\r\n"}
        ])
      end)
    end

    test "omits a matching connection that has not completed registration" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "pending_nick", registered: false)
        message = %Message{command: "USERHOST", params: [target_user.nick]}

        assert :ok = Userhost.handle(user, message)
        assert_sent_messages([{user.pid, ":irc.test 302 #{user.nick} :\r\n"}])
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
          {user.pid,
           ":irc.test 302 #{user.nick} :#{target_user.nick}=+#{target_user.ident}@#{target_user.hostname} #{target_user2.nick}=+#{target_user2.ident}@#{target_user2.hostname}\r\n"}
        ])
      end)
    end

    test "formats away, operator, truncated ident, and viewer-visible hostname fields" do
      Memento.transaction!(fn ->
        viewer = insert(:user)
        operator_viewer = insert(:user, modes: [:o])

        target_user =
          insert(:user,
            nick: "target_nick",
            ident: "longusername",
            hostname: "real.host",
            cloaked_hostname: "cloak.host",
            modes: [:o, :H, :x],
            away_message: "Away"
          )

        message = %Message{command: "USERHOST", params: [target_user.nick]}

        assert :ok = Userhost.handle(viewer, message)
        assert :ok = Userhost.handle(operator_viewer, message)

        assert_sent_messages([
          {viewer.pid, ":irc.test 302 #{viewer.nick} :#{target_user.nick}=-longuserna@cloak.host\r\n"},
          {operator_viewer.pid, ":irc.test 302 #{operator_viewer.nick} :#{target_user.nick}*=-longuserna@real.host\r\n"}
        ])
      end)
    end
  end
end
