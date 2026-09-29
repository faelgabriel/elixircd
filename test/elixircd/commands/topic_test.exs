defmodule ElixIRCd.Commands.TopicTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Topic
  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.RegisteredChannel

  @remote_origin "east.example"

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

    test "shows the selected topic of a remote-only public channel" do
      remote = build(:channel, name: "#remote-topic", topic: build(:channel_topic, text: "Remote topic"))
      publish_remote_view(remote)

      Memento.transaction!(fn ->
        user = insert(:user, nick: "Viewer")
        assert :ok = Topic.handle(user, %Message{command: "TOPIC", params: [remote.name]})

        assert_sent_messages([
          {user.pid, ":irc.test 332 Viewer #remote-topic :Remote topic\r\n"},
          {user.pid,
           ":irc.test 333 Viewer #remote-topic #{remote.topic.setter} #{DateTime.to_unix(remote.topic.set_at)}\r\n"}
        ])
      end)
    end

    test "hides a secret remote-only channel topic from outsiders" do
      remote = build(:channel, name: "#remote-secret-topic", modes: [:s])
      publish_remote_view(remote)

      Memento.transaction!(fn ->
        user = insert(:user, nick: "Viewer")
        assert :ok = Topic.handle(user, %Message{command: "TOPIC", params: [remote.name]})
        assert_sent_messages([{user.pid, ":irc.test 403 Viewer #remote-secret-topic :No such channel\r\n"}])
      end)
    end

    test "uses the selected remote topic while preserving a losing local secret restriction" do
      local = build(:channel, name: "#topic-collision", modes: [:s], topic: build(:channel_topic, text: "Local topic"))
      Memento.transaction!(fn -> Memento.Query.write(local) end)

      remote =
        build(:channel,
          name: local.name,
          created_at: DateTime.add(local.created_at, -60),
          topic: build(:channel_topic, text: "Selected topic")
        )

      view = publish_remote_view(remote, local)
      assert view.origin == @remote_origin

      Memento.transaction!(fn ->
        outsider = insert(:user, nick: "Outsider")
        member = insert(:user, nick: "Member")
        insert(:user_channel, user: member, channel: local)

        assert :ok = Topic.handle(outsider, %Message{command: "TOPIC", params: [local.name]})
        assert_sent_messages([{outsider.pid, ":irc.test 403 Outsider #topic-collision :No such channel\r\n"}])

        assert :ok = Topic.handle(member, %Message{command: "TOPIC", params: [local.name]})
        assert_sent_message_contains(member.pid, ":irc.test 332 Member #topic-collision :Selected topic\r\n")

        assert :ok = Topic.handle(member, %Message{command: "TOPIC", params: [local.name], trailing: "Wrong home"})

        assert_sent_message_contains(
          member.pid,
          ":irc.test 437 Member #topic-collision :Channel topic is temporarily unavailable on this server\r\n"
        )

        assert Memento.Query.read(Channel, local.name_key).topic.text == "Local topic"
      end)
    end

    test "uses the local topic when the local channel remains the selected authority" do
      local = build(:channel, name: "#local-topic", topic: build(:channel_topic, text: "Local topic"))
      Memento.transaction!(fn -> Memento.Query.write(local) end)

      remote =
        build(:channel,
          name: local.name,
          created_at: DateTime.add(local.created_at, 60),
          topic: build(:channel_topic, text: "Later topic")
        )

      view = publish_remote_view(remote, local)
      assert view.origin == "irc.test"

      Memento.transaction!(fn ->
        user = insert(:user, nick: "Viewer")
        assert :ok = Topic.handle(user, %Message{command: "TOPIC", params: [local.name]})
        assert_sent_message_contains(user.pid, ":irc.test 332 Viewer #local-topic :Local topic\r\n")
      end)
    end

    test "an enabled directory without the channel cannot serve or change its local topic" do
      previous = Application.fetch_env!(:elixircd, :server_links)
      on_exit(fn -> Application.put_env(:elixircd, :server_links, previous) end)
      Application.put_env(:elixircd, :server_links, Keyword.put(previous, :enabled, true))
      ChannelDirectory.create()

      {channel, user} =
        Memento.transaction!(fn ->
          channel = insert(:channel, name: "#unindexed-topic", topic: build(:channel_topic, text: "Local topic"))
          user = insert(:user, nick: "Writer")
          insert(:user_channel, user: user, channel: channel, modes: [:o])
          {channel, user}
        end)

      Memento.transaction!(fn ->
        assert :ok = Topic.handle(user, %Message{command: "TOPIC", params: [channel.name]})
        assert :ok = Topic.handle(user, %Message{command: "TOPIC", params: [channel.name], trailing: "Wrong topic"})
        assert Memento.Query.read(Channel, channel.name_key).topic.text == "Local topic"
      end)

      assert_sent_messages([
        {user.pid,
         ":irc.test 437 Writer #unindexed-topic :Channel topic is temporarily unavailable on this server\r\n"},
        {user.pid, ":irc.test 437 Writer #unindexed-topic :Channel topic is temporarily unavailable on this server\r\n"}
      ])
    end

    test "queues a remote authority TOPIC change only after the command transaction commits" do
      {local, user} =
        Memento.transaction!(fn ->
          local = insert(:channel, name: "#routed-topic", topic: nil)
          user = insert(:user, nick: "Writer")
          insert(:user_channel, user: user, channel: local)
          {local, user}
        end)

      remote = build(:channel, name: local.name, created_at: DateTime.add(local.created_at, -60))
      assert publish_remote_view(remote, local).origin == @remote_origin
      true = Process.register(self(), Hub)

      try do
        assert :ok =
                 Observability.transaction(fn ->
                   result = Topic.handle(user, %Message{command: "TOPIC", params: [local.name], trailing: "New topic"})
                   refute_received {:"$gen_cast", _message}
                   result
                 end)

        assert_receive {:"$gen_cast", {:request_topic, pid, @remote_origin, "#routed-topic", "New topic"}}
        assert pid == user.pid
        assert Memento.transaction!(fn -> Memento.Query.read(Channel, local.name_key).topic end) == nil

        assert_raise RuntimeError, fn ->
          Observability.transaction(fn ->
            Topic.handle(user, %Message{command: "TOPIC", params: [local.name], trailing: "Aborted topic"})
            raise "rollback"
          end)
        end

        refute_received {:"$gen_cast", {:request_topic, _, _, _, "Aborted topic"}}
      after
        Process.unregister(Hub)
      end
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
        assert registered_channel.settings.persistent_topic == "Locked topic"
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

  defp publish_remote_view(remote, local \\ nil) do
    table = ChannelDirectory.create()
    local_channels = if local, do: %{local.name_key => ChannelPayload.from_local(local)}, else: %{}

    replica = %Replica{
      channels: %{{@remote_origin, remote.name_key} => ChannelPayload.from_local(remote, @remote_origin)}
    }

    views = ChannelView.select("irc.test", local_channels, replica)
    ChannelDirectory.sync(table, %{}, views)
    Map.fetch!(views, remote.name_key)
  end
end
