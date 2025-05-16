defmodule ElixIRCd.Commands.JoinTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Join
  alias ElixIRCd.Message

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
      temp_config = [chanlimit: %{"#" => 2}]
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
      temp_config = [chanlimit: %{"#" => 2, "&" => 1}]
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
      temp_config = [name_length: 5]
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
      temp_config = [chantypes: ["#", "&", "+", "!"]]
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
  end
end
