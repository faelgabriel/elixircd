defmodule ElixIRCd.Services.Chanserv.RegisterTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Services.Chanserv.Register

  describe "handle/2" do
    test "handles REGISTER command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Register.handle(user, ["REGISTER"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02REGISTER\x02.\r\n"},
          {user.pid, ~r/ChanServ.*NOTICE.*Syntax: \x02REGISTER <channel> <password>\x02.*/}
        ])
      end)
    end

    test "handles REGISTER command for already registered channel" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        insert(:registered_channel, name: channel_name)
        user = insert(:user, identified_as: "founder")

        assert :ok = Register.handle(user, ["REGISTER", channel_name, "password123"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :The channel \x02#{channel_name}\x02 is already registered.\r\n"}
        ])
      end)
    end

    test "handles REGISTER command when user is not identified" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: nil)

        assert :ok = Register.handle(user, ["REGISTER", channel_name, "password123"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You must be identified to your nickname to use the \x02REGISTER\x02 command.\r\n"}
        ])
      end)
    end

    test "handles REGISTER command with invalid channel name" do
      Memento.transaction!(fn ->
        invalid_channel = "testchannel"
        user = insert(:user, identified_as: "founder")

        assert :ok = Register.handle(user, ["REGISTER", invalid_channel, "password123"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\x02#{invalid_channel}\x02 is not a valid channel name.\r\n"}
        ])
      end)
    end

    test "handles REGISTER command with password that is too short" do
      Memento.transaction!(fn ->
        min_password_length = Application.get_env(:elixircd, :services)[:chanserv][:min_password_length] || 8
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        short_password = String.duplicate("a", min_password_length - 1)

        assert :ok = Register.handle(user, ["REGISTER", channel_name, short_password])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Password is too short. Please use at least #{min_password_length} characters.\r\n"}
        ])
      end)
    end

    test "handles REGISTER command with forbidden channel name" do
      Memento.transaction!(fn ->
        channel_name = "#services"
        user = insert(:user, identified_as: "founder")

        assert :ok = Register.handle(user, ["REGISTER", channel_name, "password123"])

        assert_sent_messages([
          {user.pid, ~r/ChanServ.*NOTICE.*cannot be registered due to network policy/}
        ])

        assert {:error, :registered_channel_not_found} = RegisteredChannels.get_by_name(channel_name)
      end)
    end

    test "handles REGISTER command with forbidden channel name using regex" do
      Memento.transaction!(fn ->
        channel_name = "#opers"
        user = insert(:user, identified_as: "founder")

        channel = insert(:channel, name: channel_name)
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        assert :ok = Register.handle(user, ["REGISTER", channel_name, "password123"])

        assert_sent_messages([
          {user.pid, ~r/ChanServ.*NOTICE.*cannot be registered due to network policy/}
        ])

        assert {:error, :registered_channel_not_found} = RegisteredChannels.get_by_name(channel_name)
      end)
    end

    test "handles REGISTER command when max registered channels per user is reached" do
      Memento.transaction!(fn ->
        config = Application.get_env(:elixircd, :services)[:chanserv] || []
        max_channels = config[:max_registered_channels_per_user] || 1

        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")

        for i <- 1..max_channels do
          insert(:registered_channel, name: "#channel#{i}", founder: user.identified_as)
        end

        assert :ok = Register.handle(user, ["REGISTER", channel_name, "password123"])

        assert_sent_messages([
          {user.pid, ~r/ChanServ.*NOTICE.*reached the maximum number of registered channels/}
        ])
      end)
    end

    test "prevents non-operators from registering channels they're in" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")

        channel = insert(:channel, name: channel_name)
        insert(:user_channel, user: user, channel: channel, modes: [])

        assert :ok = Register.handle(user, ["REGISTER", channel_name, "password123"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You must be a channel operator in \x02#{channel_name}\x02 to register it.\r\n"}
        ])

        assert {:error, :registered_channel_not_found} = RegisteredChannels.get_by_name(channel_name)
      end)
    end

    test "successfully registers a channel with an operator" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        password = "password123"
        topic_text = "Test channel topic"

        channel = insert(:channel, name: channel_name, topic: build(:channel_topic, text: topic_text))
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        assert :ok = Register.handle(user, ["REGISTER", channel_name, password])

        assert_sent_messages([
          {user.pid, ~r/ChanServ.*NOTICE.*has been registered under your nickname/},
          {user.pid, ~r/ChanServ.*NOTICE.*Password accepted/},
          {user.pid, ~r/ChanServ.*NOTICE.*Remember your password/}
        ])

        assert {:ok, registered_channel} = RegisteredChannels.get_by_name(channel_name)
        assert registered_channel.name == channel_name
        assert registered_channel.founder == user.identified_as
        assert registered_channel.settings.persistent_topic == topic_text
        assert Pbkdf2.verify_pass(password, registered_channel.password_hash)
      end)
    end

    test "now properly rejects registration when channel doesn't exist" do
      Memento.transaction!(fn ->
        channel_name = "#nonexistentchannel"
        user = insert(:user, identified_as: "founder")
        password = "password123"

        assert :ok = Register.handle(user, ["REGISTER", channel_name, password])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#{channel_name}\x02 does not exist. Please join the channel before registering.\r\n"}
        ])

        assert {:error, :registered_channel_not_found} = RegisteredChannels.get_by_name(channel_name)
      end)
    end

    test "successfully registers a channel without topic set" do
      Memento.transaction!(fn ->
        channel_name = "#channelnotopic"
        user = insert(:user, identified_as: "founder")
        password = "password123"

        channel = insert(:channel, name: channel_name, topic: nil)
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        assert :ok = Register.handle(user, ["REGISTER", channel_name, password])

        assert_sent_messages([
          {user.pid, ~r/ChanServ.*NOTICE.*has been registered under your nickname/},
          {user.pid, ~r/ChanServ.*NOTICE.*Password accepted/},
          {user.pid, ~r/ChanServ.*NOTICE.*Remember your password/}
        ])

        assert {:ok, registered_channel} = RegisteredChannels.get_by_name(channel_name)
        assert registered_channel.name == channel_name
        assert registered_channel.founder == user.identified_as
        assert registered_channel.settings.persistent_topic == nil
        assert Pbkdf2.verify_pass(password, registered_channel.password_hash)
      end)
    end

    test "prevents registration when channel exists but user is not in the channel" do
      Memento.transaction!(fn ->
        channel_name = "#existingchannel"
        user = insert(:user, identified_as: "founder")

        insert(:channel, name: channel_name)

        assert :ok = Register.handle(user, ["REGISTER", channel_name, "password123"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You are not in channel \x02#{channel_name}\x02. Please join the channel first.\r\n"}
        ])

        assert {:error, :registered_channel_not_found} = RegisteredChannels.get_by_name(channel_name)
      end)
    end
  end
end
