defmodule ElixIRCd.Commands.TopicTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Topic
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.RegisteredChannel

  describe "handle/2" do
    test "handles TOPIC command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)

        message = %Message{command: "TOPIC", params: ["#anything"]}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles TOPIC command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "TOPIC", params: []}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} TOPIC :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handle TOPIC command for non-existing channel" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "TOPIC", params: ["#non-existing"]}
        assert :ok = Topic.handle(user, message)

        message = %Message{command: "TOPIC", params: ["#non-existing"], trailing: "Topic text!"}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 403 #{user.nick} #non-existing :No such channel\r\n"},
          {user.pid, ":irc.test 403 #{user.nick} #non-existing :No such channel\r\n"}
        ])
      end)
    end

    test "hides secret channel topics from non-members" do
      Memento.transaction!(fn ->
        outsider = insert(:user)
        member = insert(:user)
        channel = insert(:channel, modes: [:s])
        insert(:user_channel, user: member, channel: channel)

        message = %Message{command: "TOPIC", params: [channel.name]}
        assert :ok = Topic.handle(outsider, message)

        assert_sent_messages([{outsider.pid, ":irc.test 403 #{outsider.nick} #{channel.name} :No such channel\r\n"}])

        assert :ok = Topic.handle(member, message)

        assert_sent_message_contains(member.pid, ~r/ 332 | 331 /)
      end)
    end

    test "handles TOPIC command without topic message for a channel without a topic" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, topic: nil)

        message = %Message{command: "TOPIC", params: [channel.name]}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 331 #{user.nick} #{channel.name} :No topic is set\r\n"}
        ])
      end)
    end

    test "handles TOPIC command without topic message for a channel with a topic" do
      Memento.transaction!(fn ->
        user = insert(:user)

        channel =
          insert(:channel, %{
            topic: %Channel.Topic{text: "Channel Topic!", setter: "user!setter@host", set_at: DateTime.utc_now()}
          })

        message = %Message{command: "TOPIC", params: [channel.name]}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 332 #{user.nick} #{channel.name} :Channel Topic!\r\n"},
          {user.pid,
           ":irc.test 333 #{user.nick} #{channel.name} user!setter@host #{DateTime.to_unix(channel.topic.set_at)}\r\n"}
        ])
      end)
    end

    test "handles TOPIC command with topic message for a user not in the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)

        message = %Message{command: "TOPIC", params: [channel.name], trailing: "Topic text!"}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 442 #{user.nick} #{channel.name} :You're not on that channel\r\n"}
        ])
      end)
    end

    test "handles TOPIC command with topic message for a not-operator user in a channel with +t mode" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [:t])
        insert(:user_channel, user: user, channel: channel)

        message = %Message{command: "TOPIC", params: [channel.name], trailing: "Topic text!"}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 482 #{user.nick} #{channel.name} :You're not a channel operator\r\n"}
        ])
      end)
    end

    test "blocks direct TOPIC changes when ChanServ TOPICLOCK is enabled" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "member")
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel)

        insert(:registered_channel,
          name: channel.name,
          founder: "founder",
          settings: %{RegisteredChannel.Settings.new() | topiclock: true}
        )

        message = %Message{command: "TOPIC", params: [channel.name], trailing: "Locked topic"}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 482 #{user.nick} #{channel.name} :Topic changes are restricted by ChanServ\r\n"}
        ])
      end)
    end

    test "allows TOPIC changes for users with ChanServ T access on TOPICLOCK channels and syncs the registered topic" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel)

        insert(:registered_channel,
          name: channel.name,
          founder: "founder",
          settings: %{RegisteredChannel.Settings.new() | topiclock: true}
        )

        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "T")

        message = %Message{command: "TOPIC", params: [channel.name], trailing: "Locked topic"}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} TOPIC #{channel.name} :Locked topic\r\n"}
        ])

        {:ok, registered_channel} = RegisteredChannels.get_by_name(channel.name)
        assert registered_channel.topic.text == "Locked topic"
      end)
    end

    test "uses normal channel operator checks when a registered channel is not TOPICLOCKed" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [:t])
        insert(:user_channel, user: user, channel: channel, modes: [:o])
        insert(:registered_channel, name: channel.name, founder: "founder")

        message = %Message{command: "TOPIC", params: [channel.name], trailing: "Operator topic"}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} TOPIC #{channel.name} :Operator topic\r\n"}
        ])
      end)
    end

    test "handles TOPIC command with topic message for a not-operator user in a channel without +t mode" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel)

        message = %Message{command: "TOPIC", params: [channel.name], trailing: "Topic text!"}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} TOPIC #{channel.name} :Topic text!\r\n"}
        ])

        updated_channel = Memento.Query.read(Channel, channel.name_key)
        assert updated_channel.topic.text == "Topic text!"
        assert updated_channel.topic.setter == user_mask(user)
        assert DateTime.diff(DateTime.utc_now(), updated_channel.topic.set_at) < 1000
      end)
    end

    test "handles TOPIC command with topic message for an operator user in a channel with +t mode" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [:t])
        insert(:user_channel, user: user, channel: channel, modes: [:o])

        message = %Message{command: "TOPIC", params: [channel.name], trailing: "Topic channel text!"}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} TOPIC #{channel.name} :Topic channel text!\r\n"}
        ])

        updated_channel = Memento.Query.read(Channel, channel.name_key)
        assert updated_channel.topic.text == "Topic channel text!"
        assert updated_channel.topic.setter == user_mask(user)
        assert DateTime.diff(DateTime.utc_now(), updated_channel.topic.set_at) < 1000
      end)
    end

    test "handles TOPIC command with an empty topic message" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [:t])
        insert(:user_channel, user: user, channel: channel, modes: [:o])

        message = %Message{command: "TOPIC", params: [channel.name], trailing: ""}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} TOPIC #{channel.name} :\r\n"}
        ])

        updated_channel = Memento.Query.read(Channel, channel.name_key)
        assert updated_channel.topic == nil
      end)
    end

    test "handles TOPIC command with topic message exceeding maximum length" do
      Memento.transaction!(fn ->
        max_topic_length = Application.get_env(:elixircd, :channel)[:max_topic_length]
        user = insert(:user)
        channel = insert(:channel, modes: [], topic: nil)
        insert(:user_channel, user: user, channel: channel)

        too_long_topic = String.duplicate("a", max_topic_length + 1)
        message = %Message{command: "TOPIC", params: [channel.name], trailing: too_long_topic}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 417 #{user.nick} :Topic too long (maximum length: #{max_topic_length} characters)\r\n"}
        ])

        # Verify the topic was not changed
        updated_channel = Memento.Query.read(Channel, channel.name_key)
        assert updated_channel.topic == nil
      end)
    end
  end
end
