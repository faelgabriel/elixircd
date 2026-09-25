defmodule ElixIRCd.Commands.JoinTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Join
  alias ElixIRCd.Commands.Mode
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Tables.RegisteredChannel.Settings

  describe "handle/2" do
    for list_mode <- [:channel_ban, :channel_except, :channel_invex] do
      test "JOIN does not equate ident caret and tilde in #{list_mode}" do
        Memento.transaction!(fn ->
          user = insert(:user, ident: "~user", hostname: "host")
          channel = insert(:channel, modes: if(unquote(list_mode) == :channel_invex, do: [:i], else: []))
          if unquote(list_mode) == :channel_except, do: insert(:channel_ban, channel: channel, mask: "*!*@*")
          insert(unquote(list_mode), channel: channel, mask: "*!^user@host")
          assert :ok = Join.handle(user, %Message{command: "JOIN", params: [channel.name]})

          if unquote(list_mode) == :channel_ban do
            assert {:ok, _} = UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name)
          else
            assert {:error, :user_channel_not_found} =
                     UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name)

            numeric = if unquote(list_mode) == :channel_except, do: "474", else: "473"
            assert_sent_message_contains(user.pid, Regex.compile!(" #{numeric} "))
          end
        end)
      end
    end

    test "repeated JOIN preserves membership modes even after channel restrictions change" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [:i, {:k, "secret"}, {:l, "1"}])
        membership = insert(:user_channel, user: user, channel: channel, modes: [:o, :v])
        assert :ok = Join.handle(user, %Message{command: "JOIN", params: [String.upcase(channel.name)]})
        assert UserChannels.get_by_user_pid(user.pid) == [membership]
        assert_sent_messages_amount(user.pid, 0)
      end)
    end

    for list_mode <- [:channel_ban, :channel_except, :channel_invex] do
      test "JOIN applies IRC case mapping to #{list_mode}" do
        Memento.transaction!(fn ->
          user = insert(:user, nick: "Bar[", ident: "~User", hostname: "Host.Example")
          channel = insert(:channel, modes: if(unquote(list_mode) == :channel_invex, do: [:i], else: []))
          if unquote(list_mode) == :channel_except, do: insert(:channel_ban, channel: channel, mask: "*!*@*")
          insert(unquote(list_mode), channel: channel, mask: "bAR{!~uSER@hOST.example")
          assert :ok = Join.handle(user, %Message{command: "JOIN", params: [channel.name]})

          if unquote(list_mode) == :channel_ban do
            assert {:error, :user_channel_not_found} =
                     UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name)

            assert_sent_message_contains(user.pid, ~r/ 474 /)
          else
            assert {:ok, _} = UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name)
          end
        end)
      end
    end

    test "handles JOIN command with regex metacharacters in channel masks" do
      Memento.transaction!(fn ->
        operator = insert(:user)
        user = insert(:user)
        channel = insert(:channel)
        insert(:user_channel, user: operator, channel: channel, modes: [:o])
        assert :ok = Mode.handle(operator, %Message{command: "MODE", params: [channel.name, "+b", "*!*@(["]})
        insert(:channel_ban, channel: channel, mask: "*!*@host(")
        insert(:channel_except, channel: channel, mask: "*!*@[")
        insert(:channel_invex, channel: channel, mask: "*!*@(")

        assert :ok = Join.handle(user, %Message{command: "JOIN", params: [channel.name]})
        assert {:ok, _membership} = UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name)
      end)
    end

    for {caps, prefix} <- [{["userhost-in-names"], "@"}, {["userhost-in-names", "multi-prefix"], "@+"}],
        {channel_modes, status} <- [{[], "="}, {[:s], "@"}, {[:p], "*"}] do
      test "JOIN NAMES honors hostmasks, prefixes and channel status #{inspect({caps, channel_modes})}" do
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

          assert :ok = Join.handle(user, %Message{command: "JOIN", params: [channel.name]})

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

    test "keeps JOIN NAMES replies within 512 bytes and falls back from an oversized hostmask" do
      original_server = Application.fetch_env!(:elixircd, :server)
      server_name = String.duplicate("s", 63)
      Application.put_env(:elixircd, :server, Keyword.put(original_server, :hostname, server_name))
      on_exit(fn -> Application.put_env(:elixircd, :server, original_server) end)

      Memento.transaction!(fn ->
        user =
          insert(:user,
            nick: String.duplicate("r", 30),
            capabilities: ["userhost-in-names", "multi-prefix"]
          )

        target =
          insert(:user,
            nick: String.duplicate("t", 30),
            ident: String.duplicate("i", 64),
            hostname: String.duplicate("h", 253)
          )

        channel = insert(:channel, name: "#" <> String.duplicate("c", 64))
        insert(:user_channel, user: target, channel: channel, modes: [:o, :v])

        assert :ok = Join.handle(user, %Message{command: "JOIN", params: [channel.name]})

        names_replies =
          Agent.get(@agent_name, fn messages ->
            for {pid, message} <- messages,
                pid == user.pid,
                String.contains?(message, " 353 "),
                do: message
          end)

        assert names_replies != []
        assert Enum.all?(names_replies, &(byte_size(&1) <= 512))
        assert Enum.any?(names_replies, &String.contains?(&1, "@+#{target.nick}"))
        refute Enum.any?(names_replies, &String.contains?(&1, target.hostname))
      end)
    end

    test "handles JOIN command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "JOIN", params: ["#anything"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles JOIN command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "JOIN", params: []}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} JOIN :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles JOIN command with invalid channel name" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "JOIN", params: ["#invalid:channel"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 476 #{user.nick} #invalid:channel :Cannot join channel - invalid channel name format\r\n"}
        ])
      end)
    end

    test "handles JOIN command with non-existing channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "JOIN", params: ["#new_channel"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #new_channel\r\n"},
          {user.pid, ":irc.test MODE #new_channel +o #{user.nick}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = #new_channel :@#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #new_channel :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "restores the registered topic when recreating a KEEPTOPIC channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        restored_topic = build(:channel_topic, text: "Stored topic", setter: "ChanServ!service@irc.test")

        insert(:registered_channel,
          name: "#new_channel",
          founder: "founder",
          topic: restored_topic,
          settings: %{Settings.new() | keeptopic: true}
        )

        message = %Message{command: "JOIN", params: ["#new_channel"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #new_channel\r\n"},
          {user.pid, ":irc.test MODE #new_channel +o #{user.nick}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #new_channel :Stored topic\r\n"},
          {user.pid,
           ":irc.test 333 #{user.nick} #new_channel #{restored_topic.setter} #{DateTime.to_unix(restored_topic.set_at)}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = #new_channel :@#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #new_channel :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "restores the persistent topic snapshot when it differs from topic metadata" do
      Memento.transaction!(fn ->
        user = insert(:user)
        topic = build(:channel_topic, text: "Current metadata", setter: "operator!user@host")

        insert(:registered_channel,
          name: "#persistent_channel",
          founder: "founder",
          topic: topic,
          settings: Settings.new(%{persistent_topic: "Persistent channel topic"})
        )

        message = %Message{command: "JOIN", params: ["#persistent_channel"]}

        assert :ok = Join.handle(user, message)

        assert_sent_message_contains(
          user.pid,
          ":irc.test 332 #{user.nick} #persistent_channel :Persistent channel topic\r\n"
        )
      end)
    end

    test "restores a persistent topic when no topic metadata exists" do
      Memento.transaction!(fn ->
        user = insert(:user)

        insert(:registered_channel,
          name: "#persistent_only_channel",
          founder: "founder",
          topic: nil,
          settings: Settings.new(%{persistent_topic: "Persistent only topic"})
        )

        message = %Message{command: "JOIN", params: ["#persistent_only_channel"]}

        assert :ok = Join.handle(user, message)

        assert_sent_message_contains(
          user.pid,
          ":irc.test 332 #{user.nick} #persistent_only_channel :Persistent only topic\r\n"
        )
      end)
    end

    test "preserves topic metadata when the persistent snapshot is unchanged" do
      Memento.transaction!(fn ->
        user = insert(:user)
        topic = build(:channel_topic, text: "Unchanged topic", setter: "operator!user@host")

        insert(:registered_channel,
          name: "#unchanged_persistent_channel",
          founder: "founder",
          topic: topic,
          settings: Settings.new(%{persistent_topic: topic.text})
        )

        message = %Message{command: "JOIN", params: ["#unchanged_persistent_channel"]}

        assert :ok = Join.handle(user, message)

        assert_sent_message_contains(
          user.pid,
          ":irc.test 333 #{user.nick} #unchanged_persistent_channel #{topic.setter} #{DateTime.to_unix(topic.set_at)}\r\n"
        )
      end)
    end

    test "restores the registered topic when recreating a TOPICLOCK channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        restored_topic = build(:channel_topic, text: "Locked topic", setter: "ChanServ!service@irc.test")

        insert(:registered_channel,
          name: "#locked_channel",
          founder: "founder",
          topic: restored_topic,
          settings: %{Settings.new() | keeptopic: false, topiclock: true}
        )

        message = %Message{command: "JOIN", params: ["#locked_channel"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #locked_channel\r\n"},
          {user.pid, ":irc.test MODE #locked_channel +o #{user.nick}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #locked_channel :Locked topic\r\n"},
          {user.pid,
           ":irc.test 333 #{user.nick} #locked_channel #{restored_topic.setter} #{DateTime.to_unix(restored_topic.set_at)}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = #locked_channel :@#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #locked_channel :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "does not restore the registered topic when KEEPTOPIC and TOPICLOCK are disabled" do
      Memento.transaction!(fn ->
        user = insert(:user)
        restored_topic = build(:channel_topic, text: "Stored topic", setter: "ChanServ!service@irc.test")

        insert(:registered_channel,
          name: "#plain_channel",
          founder: "founder",
          topic: restored_topic,
          settings: Settings.new(%{keeptopic: false, topiclock: false})
        )

        message = %Message{command: "JOIN", params: ["#plain_channel"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #plain_channel\r\n"},
          {user.pid, ":irc.test MODE #plain_channel +o #{user.nick}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = #plain_channel :@#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #plain_channel :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "handles JOIN command with empty channel key" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [{:k, "password"}])
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 475 #{user.nick} #{channel.name} :Cannot join channel (+k) - bad key\r\n"}
        ])
      end)
    end

    test "handles JOIN command with wrong channel key" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [{:k, "password"}])
        message = %Message{command: "JOIN", params: [channel.name, "wrong_password"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 475 #{user.nick} #{channel.name} :Cannot join channel (+k) - bad key\r\n"}
        ])
      end)
    end

    test "handles JOIN command with channel limit reached" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [{:l, "1"}])
        insert(:user_channel, channel: channel)
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 471 #{user.nick} #{channel.name} :Cannot join channel (+l) - channel is full\r\n"}
        ])
      end)
    end

    test "allows a user to join while the channel remains below its limit" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [{:l, "2"}])
        insert(:user_channel, channel: channel)

        assert :ok = Join.handle(user, %Message{command: "JOIN", params: [channel.name]})

        assert {:ok, _user_channel} = UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name)
        assert_sent_message_contains(user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n")
      end)
    end

    test "allows a directly invited user to join a full channel and consumes the invite" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [{:l, "1"}])
        insert(:user_channel, channel: channel)
        insert(:channel_invite, channel: channel, user: user)

        assert :ok = Join.handle(user, %Message{command: "JOIN", params: [channel.name]})

        assert {:ok, _user_channel} = UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name)

        assert {:error, :channel_invite_not_found} =
                 ChannelInvites.get_by_user_pid_and_channel_name(user.pid, channel.name)

        assert_sent_message_contains(user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n")
      end)
    end

    test "does not let an invite exception bypass a full channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [:i, {:l, "1"}])
        insert(:user_channel, channel: channel)
        insert(:channel_invex, channel: channel, mask: "#{user.nick}!*@*")

        assert :ok = Join.handle(user, %Message{command: "JOIN", params: [channel.name]})

        assert_sent_messages([
          {user.pid, ":irc.test 471 #{user.nick} #{channel.name} :Cannot join channel (+l) - channel is full\r\n"}
        ])
      end)
    end

    test "does not let a direct invite bypass a channel ban" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [{:l, "1"}])
        insert(:user_channel, channel: channel)
        insert(:channel_ban, channel: channel, mask: "#{user.nick}!*@*")
        insert(:channel_invite, channel: channel, user: user)

        assert :ok = Join.handle(user, %Message{command: "JOIN", params: [channel.name]})

        assert_sent_messages([
          {user.pid, ":irc.test 474 #{user.nick} #{channel.name} :Cannot join channel (+b) - you are banned\r\n"}
        ])
      end)
    end

    test "consumes an operator invite when bypassing a ban" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)
        insert(:channel_ban, channel: channel, mask: "#{user.nick}!*@*")
        insert(:channel_invite, channel: channel, user: user, bypass_ban: true)

        assert :ok = Join.handle(user, %Message{command: "JOIN", params: [channel.name]})
        assert {:ok, _membership} = UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name)

        assert {:error, :channel_invite_not_found} =
                 ChannelInvites.get_by_user_pid_and_channel_name(user.pid, channel.name)

        assert_sent_message_contains(user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n")
      end)
    end

    test "handles JOIN command with a user banned from the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)
        insert(:channel_ban, channel: channel, mask: "#{user.nick}!*@*")
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 474 #{user.nick} #{channel.name} :Cannot join channel (+b) - you are banned\r\n"}
        ])
      end)
    end

    test "handles JOIN command with a user banned but in except list (+e)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)
        insert(:channel_ban, channel: channel, mask: "*!*@*")
        insert(:channel_except, channel: channel, mask: "#{user.nick}!*@*")
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #{channel.name} :topic\r\n"},
          {user.pid,
           ":irc.test 333 #{user.nick} #{channel.name} #{channel.topic.setter} #{DateTime.to_unix(channel.topic.set_at)}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = #{channel.name} :#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "handles JOIN command with a user banned but matching except wildcard" do
      Memento.transaction!(fn ->
        user = insert(:user, hostname: "trusted.example.com")
        channel = insert(:channel)
        insert(:channel_ban, channel: channel, mask: "*!*@*")
        insert(:channel_except, channel: channel, mask: "*!*@*.example.com")
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #{channel.name} :topic\r\n"},
          {user.pid,
           ":irc.test 333 #{user.nick} #{channel.name} #{channel.topic.setter} #{DateTime.to_unix(channel.topic.set_at)}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = #{channel.name} :#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "handles JOIN command with a user not invited to the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [:i])
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 473 #{user.nick} #{channel.name} :Cannot join channel (+i) - you are not invited\r\n"}
        ])
      end)
    end

    test "handles JOIN command with invite-only channel but user in invex list (+I)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [:i])
        insert(:channel_invex, channel: channel, mask: "#{user.nick}!*@*")
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #{channel.name} :topic\r\n"},
          {user.pid,
           ":irc.test 333 #{user.nick} #{channel.name} #{channel.topic.setter} #{DateTime.to_unix(channel.topic.set_at)}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = #{channel.name} :#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "handles JOIN command with invite-only channel but matching invex wildcard" do
      Memento.transaction!(fn ->
        user = insert(:user, hostname: "staff.company.com")
        channel = insert(:channel, modes: [:i])
        insert(:channel_invex, channel: channel, mask: "*!*@*.company.com")
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #{channel.name} :topic\r\n"},
          {user.pid,
           ":irc.test 333 #{user.nick} #{channel.name} #{channel.topic.setter} #{DateTime.to_unix(channel.topic.set_at)}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = #{channel.name} :#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "handles JOIN command with invite-only channel with direct invite takes precedence" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [:i])
        insert(:channel_invite, channel: channel, user: user)
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #{channel.name} :topic\r\n"},
          {user.pid,
           ":irc.test 333 #{user.nick} #{channel.name} #{channel.topic.setter} #{DateTime.to_unix(channel.topic.set_at)}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = #{channel.name} :#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "handles JOIN command with correct channel key, available limit, no bans and with user invited" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [{:k, "password"}, {:l, "1"}, :i])
        insert(:channel_invite, channel: channel, user: user)
        message = %Message{command: "JOIN", params: [channel.name, "password"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #{channel.name} :topic\r\n"},
          {user.pid,
           ":irc.test 333 #{user.nick} #{channel.name} #{channel.topic.setter} #{DateTime.to_unix(channel.topic.set_at)}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = #{channel.name} :#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "handles JOIN command with existing channel and another user" do
      Memento.transaction!(fn ->
        channel = insert(:channel)
        another_user = insert(:user)
        insert(:user_channel, user: another_user, channel: channel)

        user = insert(:user)
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #{channel.name} :#{channel.topic.text}\r\n"},
          {user.pid,
           ":irc.test 333 #{user.nick} #{channel.name} #{channel.topic.setter} #{DateTime.to_unix(channel.topic.set_at)}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = #{channel.name} :#{user.nick} #{another_user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"},
          {another_user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"}
        ])
      end)
    end

    test "handles JOIN command when user has reached the prefix channel limit" do
      original_channel_config = Application.get_env(:elixircd, :channel)
      temp_config = [channel_join_limits: %{"#" => 2}]
      :ok = Application.put_env(:elixircd, :channel, Keyword.merge(original_channel_config || [], temp_config))

      Memento.transaction!(fn ->
        user = insert(:user)
        # User already in 2 channels with # prefix
        channel1 = insert(:channel, name: "#channel1")
        channel2 = insert(:channel, name: "#channel2")
        insert(:user_channel, user: user, channel: channel1)
        insert(:user_channel, user: user, channel: channel2)

        # Try to join a third # channel
        message = %Message{command: "JOIN", params: ["#another_channel"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 405 #{user.nick} #another_channel :You have reached the maximum number of #-channels (2)\r\n"}
        ])
      end)

      :ok = Application.put_env(:elixircd, :channel, original_channel_config)
    end

    test "handles JOIN command with different channel prefixes respecting prefix-specific limits" do
      original_channel_config = Application.get_env(:elixircd, :channel)
      temp_config = [channel_join_limits: %{"#" => 2, "&" => 1}]
      :ok = Application.put_env(:elixircd, :channel, Keyword.merge(original_channel_config || [], temp_config))

      Memento.transaction!(fn ->
        user = insert(:user)
        # User already in 2 # channels (max limit)
        channel1 = insert(:channel, name: "#channel1")
        channel2 = insert(:channel, name: "#channel2")
        insert(:user_channel, user: user, channel: channel1)
        insert(:user_channel, user: user, channel: channel2)

        # User can still join & channel because it has a different prefix
        message = %Message{command: "JOIN", params: ["&local"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN &local\r\n"},
          {user.pid, ":irc.test MODE &local +o #{user.nick}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = &local :@#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} &local :End of NAMES list.\r\n"}
        ])

        # Try to join a second & channel
        message2 = %Message{command: "JOIN", params: ["&another_local"]}

        assert :ok = Join.handle(user, message2)

        assert_sent_messages([
          {user.pid,
           ":irc.test 405 #{user.nick} &another_local :You have reached the maximum number of &-channels (1)\r\n"}
        ])
      end)

      :ok = Application.put_env(:elixircd, :channel, original_channel_config)
    end

    test "handles JOIN command with channel name too long" do
      original_channel_config = Application.get_env(:elixircd, :channel)
      temp_config = [max_channel_name_length: 5]
      :ok = Application.put_env(:elixircd, :channel, Keyword.merge(original_channel_config || [], temp_config))

      Memento.transaction!(fn ->
        user = insert(:user)
        # Channel name with > 5 characters after prefix
        channel_name = "#toolongchannelname"
        message = %Message{command: "JOIN", params: [channel_name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 476 #{user.nick} #{channel_name} :Cannot join channel - channel name must be less or equal to 5 characters\r\n"}
        ])
      end)

      :ok = Application.put_env(:elixircd, :channel, original_channel_config)
    end

    test "handles JOIN command with custom channel types" do
      original_channel_config = Application.get_env(:elixircd, :channel)
      temp_config = [channel_prefixes: ["#", "&", "+", "!"]]
      :ok = Application.put_env(:elixircd, :channel, Keyword.merge(original_channel_config || [], temp_config))

      Memento.transaction!(fn ->
        user = insert(:user)

        # Try joining a channel with a custom prefix
        message = %Message{command: "JOIN", params: ["+customchannel"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN +customchannel\r\n"},
          {user.pid, ":irc.test MODE +customchannel +o #{user.nick}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = +customchannel :@#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} +customchannel :End of NAMES list.\r\n"}
        ])

        message2 = %Message{command: "JOIN", params: ["*invalidprefix"]}

        assert :ok = Join.handle(user, message2)

        assert_sent_messages([
          {user.pid,
           ":irc.test 476 #{user.nick} *invalidprefix :Cannot join channel - channel name must start with # or & or + or !\r\n"}
        ])
      end)

      :ok = Application.put_env(:elixircd, :channel, original_channel_config)
    end

    test "handles JOIN command with +O mode and non-IRC operator" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: [])
        channel = insert(:channel, modes: [:O])
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 520 #{user.nick} #{channel.name} :Only IRC operators may join this channel (+O)\r\n"}
        ])
      end)
    end

    test "handles JOIN command with +O mode and IRC operator" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: [:o])
        channel = insert(:channel, modes: [:O])
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #{channel.name} :#{channel.topic.text}\r\n"},
          {user.pid,
           ":irc.test 333 #{user.nick} #{channel.name} #{channel.topic.setter} #{DateTime.to_unix(channel.topic.set_at)}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = #{channel.name} :#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "handles JOIN command with +O mode combined with other restrictive modes and IRC operator" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: [:o])
        channel = insert(:channel, modes: [:O, :i, {:k, "password"}, {:l, "10"}])
        insert(:channel_invite, channel: channel, user: user)
        message = %Message{command: "JOIN", params: [channel.name, "password"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #{channel.name} :#{channel.topic.text}\r\n"},
          {user.pid,
           ":irc.test 333 #{user.nick} #{channel.name} #{channel.topic.setter} #{DateTime.to_unix(channel.topic.set_at)}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = #{channel.name} :#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "handles JOIN command with USERHOST-IN-NAMES capability enabled" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["userhost-in-names"], ident: "~testuser", hostname: "test.example.com")
        channel = insert(:channel)
        another_user = insert(:user, nick: "another_user", ident: "~another", hostname: "another.example.com")
        insert(:user_channel, user: another_user, channel: channel, modes: [:o])

        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #{channel.name} :#{channel.topic.text}\r\n"},
          {user.pid,
           ":irc.test 333 #{user.nick} #{channel.name} #{channel.topic.setter} #{DateTime.to_unix(channel.topic.set_at)}\r\n"},
          {user.pid,
           ":irc.test 353 #{user.nick} = #{channel.name} :#{user.nick}!~testuser@test.example.com @another_user!~another@another.example.com\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"},
          {another_user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"}
        ])
      end)
    end

    test "handles JOIN command without USERHOST-IN-NAMES capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [], ident: "~testuser", hostname: "test.example.com")
        channel = insert(:channel)
        another_user = insert(:user, nick: "another_user", ident: "~another", hostname: "another.example.com")
        insert(:user_channel, user: another_user, channel: channel, modes: [:o])

        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #{channel.name} :#{channel.topic.text}\r\n"},
          {user.pid,
           ":irc.test 333 #{user.nick} #{channel.name} #{channel.topic.setter} #{DateTime.to_unix(channel.topic.set_at)}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = #{channel.name} :#{user.nick} @another_user\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"},
          {another_user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"}
        ])
      end)
    end

    test "handles JOIN command creating new channel with USERHOST-IN-NAMES capability enabled" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["userhost-in-names"], ident: "~creator", hostname: "creator.example.com")
        message = %Message{command: "JOIN", params: ["#newchannel"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #newchannel\r\n"},
          {user.pid, ":irc.test MODE #newchannel +o #{user.nick}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = #newchannel :@#{user.nick}!~creator@creator.example.com\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #newchannel :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "handles JOIN command with mixed capability users in existing channel" do
      Memento.transaction!(fn ->
        channel = insert(:channel)

        hostmask_user =
          insert(:user,
            nick: "hostmask_user",
            capabilities: ["userhost-in-names"],
            ident: "~uhuser",
            hostname: "uh.example.com"
          )

        insert(:user_channel, user: hostmask_user, channel: channel, modes: [:v])

        normal_user =
          insert(:user, nick: "normal_user", capabilities: [], ident: "~normal", hostname: "normal.example.com")

        insert(:user_channel, user: normal_user, channel: channel)

        joining_user =
          insert(:user, capabilities: ["userhost-in-names"], ident: "~joining", hostname: "joining.example.com")

        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(joining_user, message)

        assert_sent_messages([
          {joining_user.pid, ":#{user_mask(joining_user)} JOIN #{channel.name}\r\n"},
          {joining_user.pid, ":irc.test 332 #{joining_user.nick} #{channel.name} :#{channel.topic.text}\r\n"},
          {joining_user.pid,
           ":irc.test 333 #{joining_user.nick} #{channel.name} #{channel.topic.setter} #{DateTime.to_unix(channel.topic.set_at)}\r\n"},
          {joining_user.pid,
           ":irc.test 353 #{joining_user.nick} = #{channel.name} :#{joining_user.nick}!~joining@joining.example.com normal_user!~normal@normal.example.com +hostmask_user!~uhuser@uh.example.com\r\n"},
          {joining_user.pid, ":irc.test 366 #{joining_user.nick} #{channel.name} :End of NAMES list.\r\n"},
          {hostmask_user.pid, ":#{user_mask(joining_user)} JOIN #{channel.name}\r\n"},
          {normal_user.pid, ":#{user_mask(joining_user)} JOIN #{channel.name}\r\n"}
        ])
      end)
    end

    test "handles JOIN command with +j mode allowing joins under throttle limit" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: [:o])
        channel = insert(:channel, name: "#test")
        insert(:user_channel, user: operator, channel: channel, modes: [:o])

        mode_message = %Message{command: "MODE", params: ["#test", "+j", "3:10"]}
        Mode.handle(operator, mode_message)

        user = insert(:user)

        join_message = %Message{command: "JOIN", params: ["#test"]}
        Join.handle(user, join_message)

        assert {:ok, _user_channel} = UserChannels.get_by_user_pid_and_channel_name(user.pid, "#test")
      end)
    end

    test "handles JOIN command with +j mode blocking joins when throttle limit exceeded" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: [:o])
        channel = insert(:channel, name: "#test")
        insert(:user_channel, user: operator, channel: channel, modes: [:o])

        mode_message = %Message{command: "MODE", params: ["#test", "+j", "2:10"]}
        Mode.handle(operator, mode_message)

        user1 = insert(:user)
        user2 = insert(:user)
        user3 = insert(:user)
        now = DateTime.utc_now()
        insert(:user_channel, user: user1, channel: channel, created_at: now)
        insert(:user_channel, user: user2, channel: channel, created_at: now)

        join_message3 = %Message{command: "JOIN", params: ["#test"]}
        Join.handle(user3, join_message3)
        assert {:error, :user_channel_not_found} = UserChannels.get_by_user_pid_and_channel_name(user3.pid, "#test")

        assert_sent_messages([
          {user3.pid, ":irc.test 477 #{user3.nick} #test :Channel join rate exceeded (+j)\r\n"}
        ])
      end)
    end

    test "handles JOIN command with +j mode exempting IRC operators from throttle" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: [:o])
        channel = insert(:channel, name: "#test")
        insert(:user_channel, user: operator, channel: channel, modes: [:o])

        mode_message = %Message{command: "MODE", params: ["#test", "+j", "2:60"]}
        Mode.handle(operator, mode_message)

        normal_user = insert(:user)
        irc_operator = insert(:user, modes: [:o])

        join_message1 = %Message{command: "JOIN", params: ["#test"]}
        Join.handle(normal_user, join_message1)

        join_message2 = %Message{command: "JOIN", params: ["#test"]}
        Join.handle(irc_operator, join_message2)

        assert {:ok, _user_channel} = UserChannels.get_by_user_pid_and_channel_name(normal_user.pid, "#test")
        assert {:ok, _user_channel} = UserChannels.get_by_user_pid_and_channel_name(irc_operator.pid, "#test")
      end)
    end

    test "handles JOIN command with +R mode blocking unregistered users" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: [:o, :r])
        channel = insert(:channel, name: "#test", modes: [:R])
        insert(:user_channel, user: operator, channel: channel, modes: [:o])

        unregistered_user = insert(:user, modes: [])
        join_message = %Message{command: "JOIN", params: ["#test"]}
        Join.handle(unregistered_user, join_message)

        assert {:error, :user_channel_not_found} =
                 UserChannels.get_by_user_pid_and_channel_name(unregistered_user.pid, "#test")

        assert_sent_messages([
          {unregistered_user.pid,
           ":irc.test 477 #{unregistered_user.nick} #test :You must be identified to join this channel (+R)\r\n"}
        ])
      end)
    end

    test "handles JOIN command with +R mode allowing registered users" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: [:o, :r])
        channel = insert(:channel, name: "#test", modes: [:R])
        insert(:user_channel, user: operator, channel: channel, modes: [:o])

        registered_user = insert(:user, modes: [:r])
        join_message = %Message{command: "JOIN", params: ["#test"]}
        Join.handle(registered_user, join_message)

        assert {:ok, _user_channel} = UserChannels.get_by_user_pid_and_channel_name(registered_user.pid, "#test")
      end)
    end

    test "handles JOIN command with +z mode blocking non-secure connections" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: [:o, :Z])
        channel = insert(:channel, name: "#test", modes: [:z])
        insert(:user_channel, user: operator, channel: channel, modes: [:o])

        insecure_user = insert(:user, modes: [])
        join_message = %Message{command: "JOIN", params: ["#test"]}
        Join.handle(insecure_user, join_message)

        assert {:error, :user_channel_not_found} =
                 UserChannels.get_by_user_pid_and_channel_name(insecure_user.pid, "#test")

        assert_sent_messages([
          {insecure_user.pid,
           ":irc.test 489 #{insecure_user.nick} #test :Cannot join channel - SSL/TLS required (+z)\r\n"}
        ])
      end)
    end

    test "handles JOIN command with +z mode allowing secure connections" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: [:o, :Z])
        channel = insert(:channel, name: "#test", modes: [:z])
        insert(:user_channel, user: operator, channel: channel, modes: [:o])

        secure_user_tls = insert(:user, modes: [:Z])
        join_message1 = %Message{command: "JOIN", params: ["#test"]}
        Join.handle(secure_user_tls, join_message1)

        secure_user_wss = insert(:user, modes: [:Z])
        join_message2 = %Message{command: "JOIN", params: ["#test"]}
        Join.handle(secure_user_wss, join_message2)

        assert {:ok, _user_channel} = UserChannels.get_by_user_pid_and_channel_name(secure_user_tls.pid, "#test")
        assert {:ok, _user_channel} = UserChannels.get_by_user_pid_and_channel_name(secure_user_wss.pid, "#test")
      end)
    end

    test "registered channel RESTRICTED blocks unidentified users" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)
        channel = insert(:channel)

        insert(:registered_channel,
          name: channel.name,
          settings: Settings.new(%{restricted: true})
        )

        Join.handle(user, %Message{command: "JOIN", params: [channel.name]})

        assert_sent_messages([
          {user.pid,
           ":irc.test 477 #{user.nick} #{channel.name} :You must be identified to an account with channel access (ChanServ RESTRICTED)\r\n"}
        ])

        assert {:error, :user_channel_not_found} =
                 UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name)
      end)
    end

    test "registered channel RESTRICTED allows identified users" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "account")
        channel = insert(:channel)

        insert(:registered_channel,
          name: channel.name,
          settings: Settings.new(%{restricted: true})
        )

        insert(:registered_channel_access, channel_name: channel.name, account_name: "account", flags: "V")

        assert :ok = Join.handle(user, %Message{command: "JOIN", params: [channel.name]})
        assert {:ok, _user_channel} = UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name)
      end)
    end

    test "registered channel SECURE does not change JOIN transport policy" do
      Memento.transaction!(fn ->
        user = insert(:user, transport: :tcp)
        channel = insert(:channel)

        insert(:registered_channel,
          name: channel.name,
          settings: Settings.new(%{secure: true})
        )

        assert :ok = Join.handle(user, %Message{command: "JOIN", params: [channel.name]})
        assert {:ok, _membership} = UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name)
      end)
    end

    test "rolls back a newly created channel after an invalid first JOIN and retries as the first member" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel_name = "#locked-first-join"

        insert(:registered_channel,
          name: channel_name,
          settings: Settings.new(%{mlock: "+lk 25 secret"})
        )

        assert :ok = Join.handle(user, %Message{command: "JOIN", params: [channel_name, "wrong"]})
        assert {:error, :channel_not_found} = Channels.get_by_name(channel_name)
        assert {:error, :user_channel_not_found} = UserChannels.get_by_user_pid_and_channel_name(user.pid, channel_name)

        assert :ok = Join.handle(user, %Message{command: "JOIN", params: [channel_name, "secret"]})
        assert {:ok, channel} = Channels.get_by_name(channel_name)
        assert {:l, "25"} in channel.modes
        assert {:k, "secret"} in channel.modes
        assert {:ok, %{modes: [:o]}} = UserChannels.get_by_user_pid_and_channel_name(user.pid, channel_name)
      end)
    end

    test "restores MLOCK +O with service authority and keeps non-operators out" do
      Memento.transaction!(fn ->
        ordinary_user = insert(:user)
        operator = insert(:user, modes: [:o])
        channel_name = "#operator-only-lock"

        insert(:registered_channel,
          name: channel_name,
          settings: Settings.new(%{mlock: "+O"})
        )

        assert :ok = Join.handle(ordinary_user, %Message{command: "JOIN", params: [channel_name]})
        assert {:error, :channel_not_found} = Channels.get_by_name(channel_name)

        assert :ok = Join.handle(operator, %Message{command: "JOIN", params: [channel_name]})
        assert {:ok, channel} = Channels.get_by_name(channel_name)
        assert :O in channel.modes

        assert :ok = Join.handle(ordinary_user, %Message{command: "JOIN", params: [channel_name]})

        assert {:error, :user_channel_not_found} =
                 UserChannels.get_by_user_pid_and_channel_name(ordinary_user.pid, channel_name)
      end)
    end

    test "registered channel entry message is delivered unless NOGREET is enabled" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "joining")
        channel = insert(:channel)

        insert(:registered_channel,
          name: channel.name,
          settings: Settings.new(%{entrymsg: "Welcome to the channel"})
        )

        assert :ok = Join.handle(user, %Message{command: "JOIN", params: [channel.name]})

        assert_sent_message_contains(
          user.pid,
          ":ChanServ!service@irc.test NOTICE joining :Welcome to the channel\r\n"
        )
      end)
    end

    test "registered channel OPNOTICE notifies existing operators when a user joins" do
      Memento.transaction!(fn ->
        operator = insert(:user, nick: "operator")
        joining_user = insert(:user, nick: "joining")
        channel = insert(:channel)
        insert(:user_channel, user: operator, channel: channel, modes: [:o])

        insert(:registered_channel,
          name: channel.name,
          settings: Settings.new(%{opnotice: true})
        )

        assert :ok = Join.handle(joining_user, %Message{command: "JOIN", params: [channel.name]})

        assert_sent_message_contains(
          operator.pid,
          ":ChanServ!service@irc.test NOTICE operator :joining has joined #{channel.name}.\r\n"
        )

        assert_sent_messages_count_containing(
          joining_user.pid,
          "has joined #{channel.name}",
          0
        )
      end)
    end

    test "handles JOIN command with +u mode showing join only to voiced/ops" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: [:o])
        channel = insert(:channel, name: "#test", modes: [:u])
        insert(:user_channel, user: operator, channel: channel, modes: [:o])

        voiced_user = insert(:user)
        insert(:user_channel, user: voiced_user, channel: channel, modes: [:v])

        normal_user = insert(:user)
        insert(:user_channel, user: normal_user, channel: channel, modes: [])

        new_normal_user = insert(:user)
        join_message = %Message{command: "JOIN", params: ["#test"]}
        Join.handle(new_normal_user, join_message)

        # Operator and voiced user should see the join
        assert_sent_message_contains(operator.pid, ~r/#{new_normal_user.nick}.*JOIN #test/)
        assert_sent_message_contains(voiced_user.pid, ~r/#{new_normal_user.nick}.*JOIN #test/)

        # Normal user should NOT see the join (auditorium mode)
        assert_sent_messages_count_containing(normal_user.pid, ~r/#{new_normal_user.nick}.*JOIN #test/, 0)
      end)
    end
  end

  describe "handle/2 - extended-join capability" do
    test "sends extended JOIN format when recipient has EXTENDED-JOIN capability (without account)" do
      Memento.transaction!(fn ->
        user = insert(:user, realname: "John Doe", capabilities: ["extended-join"])
        message = %Message{command: "JOIN", params: ["#test"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #test * :John Doe\r\n"},
          {user.pid, ":irc.test MODE #test +o #{user.nick}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = #test :@#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #test :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "sends extended JOIN format when recipient has EXTENDED-JOIN capability (with account)" do
      Memento.transaction!(fn ->
        user = insert(:user, realname: "John Doe", identified_as: "john123", capabilities: ["extended-join"])
        message = %Message{command: "JOIN", params: ["#test"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #test john123 :John Doe\r\n"},
          {user.pid, ":irc.test MODE #test +o #{user.nick}\r\n"},
          {user.pid, ":irc.test 353 #{user.nick} = #test :@#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #test :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "sends appropriate JOIN format to each user based on their capabilities" do
      Memento.transaction!(fn ->
        channel = insert(:channel, name: "#test")
        existing_user = insert(:user, realname: "Existing User", capabilities: ["extended-join"])
        insert(:user_channel, user: existing_user, channel: channel, modes: [:o])

        existing_user_without_cap = insert(:user, realname: "Regular User", capabilities: [])
        insert(:user_channel, user: existing_user_without_cap, channel: channel, modes: [])

        joining_user = insert(:user, realname: "New User", identified_as: "newuser123", capabilities: [])
        message = %Message{command: "JOIN", params: ["#test"]}

        assert :ok = Join.handle(joining_user, message)

        assert_sent_message_contains(
          existing_user.pid,
          ":#{user_mask(joining_user)} JOIN #test newuser123 :New User\r\n"
        )

        assert_sent_message_contains(
          existing_user_without_cap.pid,
          ":#{user_mask(joining_user)} JOIN #test\r\n"
        )

        assert_sent_message_contains(
          joining_user.pid,
          ":#{user_mask(joining_user)} JOIN #test\r\n"
        )
      end)
    end

    test "sends extended JOIN with asterisk when user is not identified" do
      Memento.transaction!(fn ->
        channel = insert(:channel, name: "#test")
        existing_user = insert(:user, capabilities: ["extended-join"])
        insert(:user_channel, user: existing_user, channel: channel, modes: [:o])

        joining_user = insert(:user, realname: "Anonymous User", identified_as: nil, capabilities: [])
        message = %Message{command: "JOIN", params: ["#test"]}

        assert :ok = Join.handle(joining_user, message)

        assert_sent_message_contains(
          existing_user.pid,
          ":#{user_mask(joining_user)} JOIN #test * :Anonymous User\r\n"
        )
      end)
    end

    test "includes the negotiated read marker in the JOIN response" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["draft/read-marker"])
        assert :ok = Join.handle(user, %Message{command: "JOIN", params: ["#test"]})
        assert_sent_message_contains(user.pid, ":irc.test MARKREAD #test *\r\n")
      end)
    end
  end

  test "a joining away user notifies only eligible observers" do
    Memento.transaction!(fn ->
      user = insert(:user, away_message: "Back later")
      watcher = insert(:user, capabilities: ["away-notify"])
      legacy = insert(:user)
      channel = insert(:channel)
      insert(:user_channel, user: watcher, channel: channel)
      insert(:user_channel, user: legacy, channel: channel)
      assert :ok = Join.handle(user, %Message{command: "JOIN", params: [channel.name]})
      assert_sent_messages_count_containing(watcher.pid, ~r/AWAY :Back later/, 1)
      assert_sent_messages_count_containing(legacy.pid, ~r/AWAY/, 0)
      assert_sent_messages_count_containing(user.pid, ~r/ 331 /, 0)
    end)
  end
end
