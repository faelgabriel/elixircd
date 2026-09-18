defmodule ElixIRCd.Services.Chanserv.TopicTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Services.Chanserv.Topic

  describe "handle/2" do
    test "requires identification and validates access" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Topic.handle(user, ["TOPIC", "#channel"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You must be identified with NickServ to use this command.\r\n"}
        ])

        identified_user = insert(:user, identified_as: "helper")

        assert :ok = Topic.handle(identified_user, ["TOPIC"])

        assert_sent_messages([
          {identified_user.pid,
           ":ChanServ!service@irc.test NOTICE #{identified_user.nick} :Syntax: \x02TOPIC <channel> [topic|OFF]\x02\r\n"}
        ])

        insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Topic.handle(identified_user, ["TOPIC", "#testchannel"])

        assert_sent_messages([
          {identified_user.pid,
           ":ChanServ!service@irc.test NOTICE #{identified_user.nick} :Access denied for \x02#testchannel\x02.\r\n"}
        ])
      end)
    end

    test "reports missing registered channels and shows an existing stored topic" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")

        assert :ok = Topic.handle(user, ["TOPIC", "#missing"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#missing\x02 is not registered.\r\n"}
        ])

        topic = %{text: "Stored topic", setter: "ChanServ!service@irc.test", set_at: DateTime.utc_now()}

        insert(:registered_channel, name: "#testchannel", founder: "founder", topic: topic)
        insert(:registered_channel_access, channel_name: "#testchannel", account_name: "helper", flags: "T")

        assert :ok = Topic.handle(user, ["TOPIC", "#testchannel"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Topic for \x02#testchannel\x02: \x02Stored topic\x02\r\n"}
        ])
      end)
    end

    test "shows, updates and clears the registered topic, synchronizing live channels" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        watcher = insert(:user)
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "T")
        insert(:user_channel, user: watcher, channel: channel)

        assert :ok = Topic.handle(user, ["TOPIC", channel.name])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :No topic is set for \x02#{channel.name}\x02.\r\n"}
        ])

        assert :ok = Topic.handle(user, ["TOPIC", channel.name, "Stored", "topic"])

        {:ok, registered_channel} = RegisteredChannels.get_by_name(channel.name)
        {:ok, updated_channel} = Channels.get_by_name(channel.name)

        assert registered_channel.topic.text == "Stored topic"
        assert registered_channel.settings.persistent_topic == "Stored topic"
        assert updated_channel.topic.text == "Stored topic"

        assert_sent_messages(
          [
            {watcher.pid, ":ChanServ!service@irc.test TOPIC #{channel.name} :Stored topic\r\n"},
            {user.pid,
             ":ChanServ!service@irc.test NOTICE #{user.nick} :The topic for \x02#{channel.name}\x02 has been updated.\r\n"}
          ],
          validate_order?: false
        )

        assert :ok = Topic.handle(user, ["TOPIC", channel.name, "OFF"])

        {:ok, cleared_registered_channel} = RegisteredChannels.get_by_name(channel.name)
        assert cleared_registered_channel.topic == nil
        assert cleared_registered_channel.settings.persistent_topic == nil

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :The topic for \x02#{channel.name}\x02 has been cleared.\r\n"}
        ])
      end)
    end

    test "updates the registered topic even when the channel is offline" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        registered_channel = insert(:registered_channel, name: "#testchannel", founder: "founder")

        insert(:registered_channel_access, channel_name: registered_channel.name, account_name: "helper", flags: "T")

        assert :ok = Topic.handle(user, ["TOPIC", registered_channel.name, "Offline", "topic"])

        {:ok, updated_registered_channel} = RegisteredChannels.get_by_name(registered_channel.name)
        assert updated_registered_channel.topic.text == "Offline topic"
        assert updated_registered_channel.settings.persistent_topic == "Offline topic"

        assert {:error, :channel_not_found} = Channels.get_by_name(registered_channel.name)

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :The topic for \x02#{registered_channel.name}\x02 has been updated.\r\n"}
        ])
      end)
    end

    test "reports missing channels and denied access when changing the topic" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")

        assert :ok = Topic.handle(user, ["TOPIC", "#missing", "New", "topic"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#missing\x02 is not registered.\r\n"}
        ])

        insert(:registered_channel, name: "#locked", founder: "founder")

        assert :ok = Topic.handle(user, ["TOPIC", "#locked", "New", "topic"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Access denied for \x02#locked\x02.\r\n"}
        ])
      end)
    end
  end
end
