defmodule ElixIRCd.Commands.NamesTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Names
  alias ElixIRCd.Message

  describe "handle/2" do
    for {caps, prefix} <- [{["userhost-in-names"], "@"}, {["userhost-in-names", "multi-prefix"], "@+"}],
        {channel_modes, status} <- [{[], "="}, {[:s], "@"}, {[:p], "*"}] do
      test "NAMES honors hostmasks, prefixes and channel status #{inspect({caps, channel_modes})}" do
        Memento.transaction!(fn ->
          user = insert(:user, capabilities: unquote(caps))

          target =
            insert(:user,
              nick: "target",
              ident: "~target",
              hostname: "private.example",
              cloaked_hostname: "cloak.example",
              modes: [:x]
            )

          channel = insert(:channel, modes: unquote(channel_modes))
          insert(:user_channel, user: target, channel: channel, modes: [:v, :o])
          insert(:user_channel, user: user, channel: channel)
          assert :ok = Names.handle(user, %Message{command: "NAMES", params: [channel.name]})

          assert_sent_message_contains(
            user.pid,
            ~r/:irc\.test 353 #{user.nick} #{Regex.escape(unquote(status))} #{channel.name} :/
          )

          assert_sent_message_contains(user.pid, ~r/#{Regex.escape(unquote(prefix))}target!~target@cloak\.example/)
          assert_sent_messages_count_containing(user.pid, ~r/private\.example/, 0)
          assert_sent_messages_count_containing(user.pid, ~r/ 366 /, 1)
        end)
      end
    end

    test "keeps NAMES replies within the wire budget with maximum protocol fields" do
      original_server = Application.fetch_env!(:elixircd, :server)
      server_name = String.duplicate("s", 63)
      Application.put_env(:elixircd, :server, Keyword.put(original_server, :hostname, server_name))
      on_exit(fn -> Application.put_env(:elixircd, :server, original_server) end)

      Memento.transaction!(fn ->
        requesting_nick = String.duplicate("r", 30)
        target_nick = String.duplicate("t", 30)
        channel_name = "#" <> String.duplicate("c", 199)
        user = insert(:user, nick: requesting_nick, capabilities: ["userhost-in-names"])

        target =
          insert(:user,
            nick: target_nick,
            ident: String.duplicate("i", 64),
            hostname: String.duplicate("h", 253)
          )

        channel = insert(:channel, name: channel_name)
        insert(:user_channel, user: target, channel: channel)

        assert :ok = Names.handle(user, %Message{command: "NAMES", params: [channel.name]})

        names_reply = ":#{server_name} 353 #{user.nick} = #{channel.name} :#{target.nick}\r\n"
        end_reply = ":#{server_name} 366 #{user.nick} #{channel.name} :End of /NAMES list\r\n"
        assert byte_size(names_reply) <= 512
        assert byte_size(end_reply) <= 512
        assert_sent_messages([{user.pid, names_reply}, {user.pid, end_reply}])
      end)
    end

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
        channel2 = insert(:channel, name: "#channel2", modes: [:s])
        user1 = insert(:user, nick: "user1")
        user2 = insert(:user, nick: "user2")
        user3 = insert(:user, nick: "user3")
        _free_user = insert(:user, nick: "free_user")

        insert(:user_channel, user: user1, channel: channel1, modes: [:o])
        insert(:user_channel, user: user2, channel: channel1, modes: [:v])
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

        insert(:user_channel, user: user1, channel: channel, modes: [:o])
        insert(:user_channel, user: user2, channel: channel, modes: [:v])

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
        channel2 = insert(:channel, name: "#channel2", modes: [:p])
        user1 = insert(:user, nick: "user1")
        user2 = insert(:user, nick: "user2")

        insert(:user_channel, user: user1, channel: channel1, modes: [:o])
        insert(:user_channel, user: user2, channel: channel2, modes: [:v])

        message = %Message{command: "NAMES", params: ["#channel1,#channel2"]}
        assert :ok = Names.handle(user, message)

        # Since #channel2 is private, and the user is not a member, they should only see #channel1
        # and receive the end-of-list reply for #channel2
        assert_sent_messages([
          {user.pid, ":irc.test 353 #{user.nick} = #{channel1.name} :@user1\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel1.name} :End of /NAMES list\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #channel2 :End of /NAMES list\r\n"}
        ])
      end)
    end

    test "handles NAMES command with non-existent channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "NAMES", params: ["#nonexistent"]}

        assert :ok = Names.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 366 #{user.nick} #nonexistent :End of /NAMES list\r\n"}
        ])
      end)
    end

    test "handles NAMES command with invalid channel name" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "NAMES", params: ["invalid.channel"]}

        assert :ok = Names.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 366 #{user.nick} invalid.channel :End of /NAMES list\r\n"}
        ])
      end)
    end

    for in_channel? <- [false, true] do
      test "NAMES keeps +H users visible with channel membership=#{in_channel?}" do
        Memento.transaction!(fn ->
          user = insert(:user)
          target = insert(:user, nick: "hidden", modes: [:o, :H])

          params =
            if unquote(in_channel?) do
              channel = insert(:channel)
              insert(:user_channel, user: target, channel: channel)
              [channel.name]
            else
              []
            end

          assert :ok = Names.handle(user, %Message{command: "NAMES", params: params})
          assert_sent_messages_count_containing(user.pid, ~r/ 353 .* :hidden\r\n$/, 1)
        end)
      end
    end

    test "handles NAMES command with invisible users" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#channel")
        user_visible = insert(:user, nick: "visible")
        user_invisible = insert(:user, nick: "invisible", modes: [:i])

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
        operator = insert(:user, modes: [:o])
        channel = insert(:channel, name: "#channel")
        user_visible = insert(:user, nick: "visible")
        user_invisible = insert(:user, nick: "invisible", modes: [:i])

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
        channel = insert(:channel, name: "#secret", modes: [:s])
        user1 = insert(:user, nick: "user1")
        user2 = insert(:user, nick: "user2")

        insert(:user_channel, user: user1, channel: channel)
        insert(:user_channel, user: user2, channel: channel)

        message = %Message{command: "NAMES", params: [channel.name]}
        assert :ok = Names.handle(user, message)

        # Should not see the channel since user is not a member
        assert_sent_messages([
          {user.pid, ":irc.test 366 #{user.nick} #secret :End of /NAMES list\r\n"}
        ])
      end)
    end

    test "handles NAMES command with private channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#private", modes: [:p])
        user1 = insert(:user, nick: "user1")
        user2 = insert(:user, nick: "user2")

        insert(:user_channel, user: user1, channel: channel)
        insert(:user_channel, user: user2, channel: channel)

        message = %Message{command: "NAMES", params: [channel.name]}
        assert :ok = Names.handle(user, message)

        # Should not see the channel since user is not a member
        assert_sent_messages([
          {user.pid, ":irc.test 366 #{user.nick} #private :End of /NAMES list\r\n"}
        ])
      end)
    end

    test "handles NAMES command with invisible free user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        _visible_free_user = insert(:user, nick: "visible_free")
        _invisible_free_user = insert(:user, nick: "invisible_free", modes: [:i])

        message = %Message{command: "NAMES", params: []}
        assert :ok = Names.handle(user, message)

        # The invisible user should not be shown in the free users list
        assert_sent_messages([
          {user.pid, ":irc.test 353 #{user.nick} * * :visible_free\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} * :End of /NAMES list\r\n"}
        ])
      end)
    end

    test "does not expose connections that have not completed registration" do
      Memento.transaction!(fn ->
        user = insert(:user)
        _visible_user = insert(:user, nick: "visible")
        _pending_user = insert(:user, nick: "pending", registered: false)

        assert :ok = Names.handle(user, %Message{command: "NAMES", params: []})

        assert_sent_messages([
          {user.pid, ":irc.test 353 #{user.nick} * * :visible\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} * :End of /NAMES list\r\n"}
        ])
      end)
    end

    test "handles NAMES command when user is a member of a private channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        private_channel = insert(:channel, name: "#private", modes: [:p])
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

    test "handles NAMES command with all channels when some channels are deleted" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#test")
        user1 = insert(:user, nick: "testuser")
        insert(:user_channel, user: user1, channel: channel)
        Memento.Query.delete_record(channel)

        message = %Message{command: "NAMES", params: []}
        assert :ok = Names.handle(user, message)
        assert_sent_messages([])
      end)
    end

    test "handles NAMES command with USERHOST-IN-NAMES capability enabled" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["userhost-in-names"])
        channel = insert(:channel, name: "#channel")
        user1 = insert(:user, nick: "user1", ident: "~ident1", hostname: "host1.example.com")
        insert(:user_channel, user: user1, channel: channel)

        message = %Message{command: "NAMES", params: [channel.name]}
        assert :ok = Names.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 353 #{user.nick} = #{channel.name} :user1!~ident1@host1.example.com\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of /NAMES list\r\n"}
        ])
      end)
    end

    test "handles NAMES command without USERHOST-IN-NAMES capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        channel = insert(:channel, name: "#channel2")
        user1 = insert(:user, nick: "user1", ident: "~ident1", hostname: "host1.example.com")
        insert(:user_channel, user: user1, channel: channel)
        message = %Message{command: "NAMES", params: [channel.name]}
        assert :ok = Names.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 353 #{user.nick} = #{channel.name} :user1\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of /NAMES list\r\n"}
        ])
      end)
    end

    test "handles NAMES command with free users and USERHOST-IN-NAMES capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["userhost-in-names"])
        _free_user = insert(:user, nick: "free_user", ident: "~freeuser", hostname: "freehost.example.com")
        message = %Message{command: "NAMES", params: []}
        assert :ok = Names.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 353 #{user.nick} * * :free_user!~freeuser@freehost.example.com\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} * :End of /NAMES list\r\n"}
        ])
      end)
    end

    test "handles NAMES command with all channels including secret channel not visible to user" do
      Memento.transaction!(fn ->
        user = insert(:user)
        secret_channel = insert(:channel, name: "#secret", modes: [:s])
        other_user = insert(:user, nick: "other_user")
        insert(:user_channel, user: other_user, channel: secret_channel)
        message = %Message{command: "NAMES", params: []}
        assert :ok = Names.handle(user, message)
        assert_sent_messages([])
      end)
    end

    test "handles NAMES with MULTI-PREFIX capability showing all prefixes" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["multi-prefix"])
        channel = insert(:channel, name: "#test")

        dual_prefix_user = insert(:user)
        insert(:user_channel, user: dual_prefix_user, channel: channel, modes: [:o, :v])

        op_user = insert(:user)
        insert(:user_channel, user: op_user, channel: channel, modes: [:o])

        voice_user = insert(:user)
        insert(:user_channel, user: voice_user, channel: channel, modes: [:v])

        normal_user = insert(:user)
        insert(:user_channel, user: normal_user, channel: channel)

        message = %Message{command: "NAMES", params: ["#test"]}
        assert :ok = Names.handle(user, message)

        assert_sent_messages([
          {user.pid, ~r/:irc.test 353 #{user.nick} = #test :.*@\+#{dual_prefix_user.nick}.*/},
          {user.pid, ":irc.test 366 #{user.nick} #test :End of /NAMES list\r\n"}
        ])
      end)
    end

    test "handles NAMES without MULTI-PREFIX showing only highest prefix" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#test")

        dual_prefix_user = insert(:user)
        insert(:user_channel, user: dual_prefix_user, channel: channel, modes: [:o, :v])

        message = %Message{command: "NAMES", params: ["#test"]}
        assert :ok = Names.handle(user, message)

        assert_sent_messages([
          {user.pid, ~r/:irc.test 353 #{user.nick} = #test :@#{dual_prefix_user.nick}/},
          {user.pid, ":irc.test 366 #{user.nick} #test :End of /NAMES list\r\n"}
        ])
      end)
    end

    test "always sends 366 for visible channels even when all nicks are hidden" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#hidden_test", modes: [])
        hidden_user = insert(:user, modes: [:i])
        insert(:user_channel, user: hidden_user, channel: channel)

        message = %Message{command: "NAMES", params: ["#hidden_test"]}
        assert :ok = Names.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 366 #{user.nick} #hidden_test :End of /NAMES list\r\n"}
        ])
      end)
    end

    test "shows +i fellow members to channel members" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, name: "#member_test", modes: [])
        hidden_member = insert(:user, nick: "hidden_member", modes: [:i])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: hidden_member, channel: channel)

        message = %Message{command: "NAMES", params: ["#member_test"]}
        assert :ok = Names.handle(user, message)

        assert_sent_messages([
          {user.pid, ~r/:irc.test 353 #{user.nick} = #member_test :.*hidden_member/},
          {user.pid, ":irc.test 366 #{user.nick} #member_test :End of /NAMES list\r\n"}
        ])
      end)
    end
  end
end
