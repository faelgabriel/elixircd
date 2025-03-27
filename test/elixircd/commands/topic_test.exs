defmodule ElixIRCd.Commands.TopicTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Topic
  alias ElixIRCd.Message
  alias ElixIRCd.Tables.Channel

  describe "handle/2" do
    test "handles TOPIC command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)

        message = %Message{command: "TOPIC", params: ["#anything"]}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles TOPIC command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "TOPIC", params: []}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 461 #{user.nick} TOPIC :Not enough parameters\r\n"}
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
          {user.pid, ":server.example.com 403 #{user.nick} #non-existing :No such channel\r\n"},
          {user.pid, ":server.example.com 403 #{user.nick} #non-existing :No such channel\r\n"}
        ])
      end)
    end

    test "handles TOPIC command without topic message for a channel without a topic" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, topic: nil)

        message = %Message{command: "TOPIC", params: [channel.name]}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 331 #{user.nick} #{channel.name} :No topic is set\r\n"}
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
          {user.pid, ":server.example.com 332 #{user.nick} #{channel.name} :Channel Topic!\r\n"},
          {user.pid,
           ":server.example.com 333 #{user.nick} #{channel.name} user!setter@host #{DateTime.to_unix(channel.topic.set_at)}\r\n"}
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
          {user.pid, ":server.example.com 442 #{user.nick} #{channel.name} :You're not on that channel\r\n"}
        ])
      end)
    end

    test "handles TOPIC command with topic message for a not-operator user in a channel with +t mode" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["t"])
        insert(:user_channel, user: user, channel: channel)

        message = %Message{command: "TOPIC", params: [channel.name], trailing: "Topic text!"}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":server.example.com 482 #{user.nick} #{channel.name} :You're not a channel operator\r\n"}
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

        updated_channel = Memento.Query.read(Channel, channel.name)
        assert updated_channel.topic.text == "Topic text!"
        assert updated_channel.topic.setter == user_mask(user)
        assert DateTime.diff(DateTime.utc_now(), updated_channel.topic.set_at) < 1000
      end)
    end

    test "handles TOPIC command with topic message for an operator user in a channel with +t mode" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["t"])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "TOPIC", params: [channel.name], trailing: "Topic channel text!"}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} TOPIC #{channel.name} :Topic channel text!\r\n"}
        ])

        updated_channel = Memento.Query.read(Channel, channel.name)
        assert updated_channel.topic.text == "Topic channel text!"
        assert updated_channel.topic.setter == user_mask(user)
        assert DateTime.diff(DateTime.utc_now(), updated_channel.topic.set_at) < 1000
      end)
    end

    test "handles TOPIC command with an empty topic message" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["t"])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "TOPIC", params: [channel.name], trailing: ""}
        assert :ok = Topic.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} TOPIC #{channel.name} :\r\n"}
        ])

        updated_channel = Memento.Query.read(Channel, channel.name)
        assert updated_channel.topic == nil
      end)
    end
  end
end
