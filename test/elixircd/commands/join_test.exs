defmodule ElixIRCd.Commands.JoinTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Join
  alias ElixIRCd.Commands.Mode
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.UserChannels

  describe "handle/2" do
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
        message = %Message{command: "JOIN", params: ["#invalid.channel.name"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 476 #{user.nick} #invalid.channel.name :Cannot join channel - invalid channel name format\r\n"}
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
          {user.pid, ":irc.test 331 #{user.nick} #new_channel :No topic is set\r\n"},
          {user.pid, ":irc.test 353 = #{user.nick} #new_channel :@#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #new_channel :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "handles JOIN command with empty channel key" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [{"k", "password"}])
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
        channel = insert(:channel, modes: [{"k", "password"}])
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
        channel = insert(:channel, modes: [{"l", "1"}])
        insert(:user_channel, channel: channel)
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 471 #{user.nick} #{channel.name} :Cannot join channel (+l) - channel is full\r\n"}
        ])
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

    test "handles JOIN command with a user not invited to the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["i"])
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 473 #{user.nick} #{channel.name} :Cannot join channel (+i) - you are not invited\r\n"}
        ])
      end)
    end

    test "handles JOIN command with correct channel key, available limit, no bans and with user invited" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [{"k", "password"}, {"l", "1"}, "i"])
        insert(:channel_invite, channel: channel, user: user)
        message = %Message{command: "JOIN", params: [channel.name, "password"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #{channel.name} :topic\r\n"},
          {user.pid, ":irc.test 353 = #{user.nick} #{channel.name} :#{user.nick}\r\n"},
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
          {user.pid, ":irc.test 353 = #{user.nick} #{channel.name} :#{user.nick} #{another_user.nick}\r\n"},
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
          {user.pid, ":irc.test 331 #{user.nick} &local :No topic is set\r\n"},
          {user.pid, ":irc.test 353 = #{user.nick} &local :@#{user.nick}\r\n"},
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
          {user.pid, ":irc.test 331 #{user.nick} +customchannel :No topic is set\r\n"},
          {user.pid, ":irc.test 353 = #{user.nick} +customchannel :@#{user.nick}\r\n"},
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
        channel = insert(:channel, modes: ["O"])
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 520 #{user.nick} #{channel.name} :Only IRC operators may join this channel (+O)\r\n"}
        ])
      end)
    end

    test "handles JOIN command with +O mode and IRC operator" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        channel = insert(:channel, modes: ["O"])
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #{channel.name} :#{channel.topic.text}\r\n"},
          {user.pid, ":irc.test 353 = #{user.nick} #{channel.name} :#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "handles JOIN command with +O mode combined with other restrictive modes and IRC operator" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        channel = insert(:channel, modes: ["O", "i", {"k", "password"}, {"l", "10"}])
        insert(:channel_invite, channel: channel, user: user)
        message = %Message{command: "JOIN", params: [channel.name, "password"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #{channel.name} :#{channel.topic.text}\r\n"},
          {user.pid, ":irc.test 353 = #{user.nick} #{channel.name} :#{user.nick}\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "handles JOIN command with UHNAMES capability enabled" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["UHNAMES"], ident: "~testuser", hostname: "test.example.com")
        channel = insert(:channel)
        another_user = insert(:user, nick: "another_user", ident: "~another", hostname: "another.example.com")
        insert(:user_channel, user: another_user, channel: channel, modes: ["o"])

        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #{channel.name} :#{channel.topic.text}\r\n"},
          {user.pid,
           ":irc.test 353 = #{user.nick} #{channel.name} :#{user.nick}!~testuser@test.example.com @another_user!~another@another.example.com\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"},
          {another_user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"}
        ])
      end)
    end

    test "handles JOIN command without UHNAMES capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [], ident: "~testuser", hostname: "test.example.com")
        channel = insert(:channel)
        another_user = insert(:user, nick: "another_user", ident: "~another", hostname: "another.example.com")
        insert(:user_channel, user: another_user, channel: channel, modes: ["o"])

        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"},
          {user.pid, ":irc.test 332 #{user.nick} #{channel.name} :#{channel.topic.text}\r\n"},
          {user.pid, ":irc.test 353 = #{user.nick} #{channel.name} :#{user.nick} @another_user\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #{channel.name} :End of NAMES list.\r\n"},
          {another_user.pid, ":#{user_mask(user)} JOIN #{channel.name}\r\n"}
        ])
      end)
    end

    test "handles JOIN command creating new channel with UHNAMES capability enabled" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["UHNAMES"], ident: "~creator", hostname: "creator.example.com")
        message = %Message{command: "JOIN", params: ["#newchannel"]}

        assert :ok = Join.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} JOIN #newchannel\r\n"},
          {user.pid, ":irc.test MODE #newchannel +o #{user.nick}\r\n"},
          {user.pid, ":irc.test 331 #{user.nick} #newchannel :No topic is set\r\n"},
          {user.pid, ":irc.test 353 = #{user.nick} #newchannel :@#{user.nick}!~creator@creator.example.com\r\n"},
          {user.pid, ":irc.test 366 #{user.nick} #newchannel :End of NAMES list.\r\n"}
        ])
      end)
    end

    test "handles JOIN command with mixed capability users in existing channel" do
      Memento.transaction!(fn ->
        channel = insert(:channel)

        uhnames_user =
          insert(:user, nick: "uhnames_user", capabilities: ["UHNAMES"], ident: "~uhuser", hostname: "uh.example.com")

        insert(:user_channel, user: uhnames_user, channel: channel, modes: ["v"])

        normal_user =
          insert(:user, nick: "normal_user", capabilities: [], ident: "~normal", hostname: "normal.example.com")

        insert(:user_channel, user: normal_user, channel: channel)

        joining_user = insert(:user, capabilities: ["UHNAMES"], ident: "~joining", hostname: "joining.example.com")
        message = %Message{command: "JOIN", params: [channel.name]}

        assert :ok = Join.handle(joining_user, message)

        assert_sent_messages([
          {joining_user.pid, ":#{user_mask(joining_user)} JOIN #{channel.name}\r\n"},
          {joining_user.pid, ":irc.test 332 #{joining_user.nick} #{channel.name} :#{channel.topic.text}\r\n"},
          {joining_user.pid,
           ":irc.test 353 = #{joining_user.nick} #{channel.name} :#{joining_user.nick}!~joining@joining.example.com normal_user!~normal@normal.example.com +uhnames_user!~uhuser@uh.example.com\r\n"},
          {joining_user.pid, ":irc.test 366 #{joining_user.nick} #{channel.name} :End of NAMES list.\r\n"},
          {uhnames_user.pid, ":#{user_mask(joining_user)} JOIN #{channel.name}\r\n"},
          {normal_user.pid, ":#{user_mask(joining_user)} JOIN #{channel.name}\r\n"}
        ])
      end)
    end

    test "handles JOIN command with +j mode allowing joins under throttle limit" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: ["o"])
        channel = insert(:channel, name: "#test")
        insert(:user_channel, user: operator, channel: channel, modes: ["o"])

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
        operator = insert(:user, modes: ["o"])
        channel = insert(:channel, name: "#test")
        insert(:user_channel, user: operator, channel: channel, modes: ["o"])

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
        operator = insert(:user, modes: ["o"])
        channel = insert(:channel, name: "#test")
        insert(:user_channel, user: operator, channel: channel, modes: ["o"])

        mode_message = %Message{command: "MODE", params: ["#test", "+j", "2:60"]}
        Mode.handle(operator, mode_message)

        normal_user = insert(:user)
        irc_operator = insert(:user, modes: ["o"])

        join_message1 = %Message{command: "JOIN", params: ["#test"]}
        Join.handle(normal_user, join_message1)

        join_message2 = %Message{command: "JOIN", params: ["#test"]}
        Join.handle(irc_operator, join_message2)

        assert {:ok, _user_channel} = UserChannels.get_by_user_pid_and_channel_name(normal_user.pid, "#test")
        assert {:ok, _user_channel} = UserChannels.get_by_user_pid_and_channel_name(irc_operator.pid, "#test")
      end)
    end
  end
end
