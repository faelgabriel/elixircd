defmodule ElixIRCd.Commands.NamesTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Names
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles NAMES command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "NAMES", params: ["#anything"]}

        assert :ok = Names.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles NAMES command with no channels specified" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel1 = insert(:channel, name: "#channel1")
        channel2 = insert(:channel, name: "#channel2", modes: ["s"])
        user1 = insert(:user, nick: "user1")
        user2 = insert(:user, nick: "user2")
        user3 = insert(:user, nick: "user3")
        _free_user = insert(:user, nick: "free_user")

        insert(:user_channel, user: user1, channel: channel1, modes: ["o"])
        insert(:user_channel, user: user2, channel: channel1, modes: ["v"])
        insert(:user_channel, user: user3, channel: channel2)

        message = %Message{command: "NAMES", params: []}
        assert :ok = Names.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 353 #{user.nick} = #{channel1.name} :@user1 +user2\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel1.name} :End of /NAMES list\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} * * :free_user\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} * :End of /NAMES list\r\n"}
        ])
      end)
    end

    test "handles NAMES command with specific channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#channel")
        user1 = insert(:user, nick: "user1")
        user2 = insert(:user, nick: "user2")

        insert(:user_channel, user: user1, channel: channel, modes: ["o"])
        insert(:user_channel, user: user2, channel: channel, modes: ["v"])

        message = %Message{command: "NAMES", params: [channel.name]}
        assert :ok = Names.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 353 #{user.nick} = #{channel.name} :@user1 +user2\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of /NAMES list\r\n"}
        ])
      end)
    end

    test "handles NAMES command with multiple channels" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel1 = insert(:channel, name: "#channel1")
        channel2 = insert(:channel, name: "#channel2", modes: ["p"])
        user1 = insert(:user, nick: "user1")
        user2 = insert(:user, nick: "user2")

        insert(:user_channel, user: user1, channel: channel1, modes: ["o"])
        insert(:user_channel, user: user2, channel: channel2, modes: ["v"])

        message = %Message{command: "NAMES", params: ["#channel1,#channel2"]}
        assert :ok = Names.handle(user, message)

        # Since #channel2 is private, and the user is not a member, they should only see #channel1
        # but also receive a "No such channel" response for #channel2
        assert_sent_messages([
          {user.pid, ":irc.test 353 #{user.nick} = #{channel1.name} :@user1\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel1.name} :End of /NAMES list\r\n"},
          {user.pid, ":irc.test 403 #{user.nick} #channel2 :No such channel\r\n"}
        ])
      end)
    end

    test "handles NAMES command with non-existent channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "NAMES", params: ["#nonexistent"]}

        assert :ok = Names.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 403 #{user.nick} #nonexistent :No such channel\r\n"}
        ])
      end)
    end

    test "handles NAMES command with invalid channel name" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "NAMES", params: ["invalid.channel"]}

        assert :ok = Names.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 403 #{user.nick} invalid.channel :No such channel\r\n"}
        ])
      end)
    end

    test "handles NAMES command with invisible users" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#channel")
        user_visible = insert(:user, nick: "visible")
        user_invisible = insert(:user, nick: "invisible", modes: ["i"])

        insert(:user_channel, user: user_visible, channel: channel)
        insert(:user_channel, user: user_invisible, channel: channel)

        message = %Message{command: "NAMES", params: [channel.name]}
        assert :ok = Names.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 353 #{user.nick} = #{channel.name} :visible\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of /NAMES list\r\n"}
        ])
      end)
    end

    test "handles NAMES command with operator seeing invisible users" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: ["o"])
        channel = insert(:channel, name: "#channel")
        user_visible = insert(:user, nick: "visible")
        user_invisible = insert(:user, nick: "invisible", modes: ["i"])

        insert(:user_channel, user: user_visible, channel: channel)
        insert(:user_channel, user: user_invisible, channel: channel)

        message = %Message{command: "NAMES", params: [channel.name]}
        assert :ok = Names.handle(operator, message)

        assert_sent_messages([
          {operator.pid, ":irc.test 353 #{operator.nick} = #{channel.name} :invisible visible\r\n"},
          {operator.pid, ":irc.test 366 #{operator.nick} #{channel.name} :End of /NAMES list\r\n"}
        ])
      end)
    end

    test "handles NAMES command with secret channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#secret", modes: ["s"])
        user1 = insert(:user, nick: "user1")
        user2 = insert(:user, nick: "user2")

        insert(:user_channel, user: user1, channel: channel)
        insert(:user_channel, user: user2, channel: channel)

        message = %Message{command: "NAMES", params: [channel.name]}
        assert :ok = Names.handle(user, message)

        # Should not see the channel since user is not a member
        assert_sent_messages([
          {user.pid, ":irc.test 403 #{user.nick} #secret :No such channel\r\n"}
        ])
      end)
    end

    test "handles NAMES command with private channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#private", modes: ["p"])
        user1 = insert(:user, nick: "user1")
        user2 = insert(:user, nick: "user2")

        insert(:user_channel, user: user1, channel: channel)
        insert(:user_channel, user: user2, channel: channel)

        message = %Message{command: "NAMES", params: [channel.name]}
        assert :ok = Names.handle(user, message)

        # Should not see the channel since user is not a member
        assert_sent_messages([
          {user.pid, ":irc.test 403 #{user.nick} #private :No such channel\r\n"}
        ])
      end)
    end

    test "handles NAMES command with invisible free user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        _visible_free_user = insert(:user, nick: "visible_free")
        _invisible_free_user = insert(:user, nick: "invisible_free", modes: ["i"])

        message = %Message{command: "NAMES", params: []}
        assert :ok = Names.handle(user, message)

        # The invisible user should not be shown in the free users list
        assert_sent_messages([
          {user.pid, ":irc.test 353 #{user.nick} * * :visible_free\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} * :End of /NAMES list\r\n"}
        ])
      end)
    end

    test "handles NAMES command when user is a member of a private channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        private_channel = insert(:channel, name: "#private", modes: ["p"])
        insert(:user_channel, user: user, channel: private_channel)
        other_user = insert(:user, nick: "other_user")
        insert(:user_channel, user: other_user, channel: private_channel)

        message = %Message{command: "NAMES", params: [private_channel.name]}
        assert :ok = Names.handle(user, message)

        # User should see the private channel's contents because they're a member
        assert_sent_messages([
          {user.pid, ":irc.test 353 #{user.nick} * #{private_channel.name} :#{user.nick} other_user\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{private_channel.name} :End of /NAMES list\r\n"}
        ])
      end)
    end
  end
end
