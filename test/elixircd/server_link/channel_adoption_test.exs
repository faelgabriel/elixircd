defmodule ElixIRCd.ServerLink.ChannelAdoptionTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Join
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelExcepts
  alias ElixIRCd.Repositories.ChannelInvexes
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.ServerLink.ChannelAuthority
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.ChannelReconciler
  alias ElixIRCd.ServerLink.ChannelState
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.ChannelIdentity
  alias ElixIRCd.Utils.CaseMapping

  test "a remote-only channel is adopted with its identity and no creator operator grant" do
    topic = build(:channel_topic, text: "Network topic", setter: "Remote!user@east.example")
    source = build(:channel, name: "#adopted", modes: [:n, {:k, "secret"}], topic: topic)
    uid = String.duplicate("a", 32)
    remote_user = build(:user, nick: "Remote", hostname: "east.example")

    remote_member = %{
      origin: "east.example",
      member: %{"uid" => uid},
      user: UserPayload.from_local(remote_user, uid),
      effective_modes: ["o"]
    }

    view = publish(source, members: [remote_member])

    Memento.transaction!(fn ->
      first = insert(:user, nick: "First")
      assert :ok = Join.handle(first, %Message{command: "JOIN", params: [source.name, "secret"]})
      assert {:ok, channel} = Channels.get_by_name(source.name)
      assert channel.created_at == source.created_at
      assert channel.topic.text == "Network topic"
      assert MapSet.new(channel.modes) == MapSet.new([:n, {:k, "secret"}])
      assert %ChannelIdentity{creator: "east.example"} = Memento.Query.read(ChannelIdentity, channel.name_key)
      assert {:ok, membership} = UserChannels.get_by_user_pid_and_channel_name(first.pid, channel.name)
      assert membership.modes == []
      assert_sent_message_contains(first.pid, ~r/ JOIN #adopted/)
      assert_sent_message_contains(first.pid, ~r/ 353 First = #adopted :.*@Remote/)
      assert_sent_messages_count_containing(first.pid, ~r/ MODE #adopted \+o /, 0)

      second = insert(:user, nick: "Second")
      assert :ok = Join.handle(second, %Message{command: "JOIN", params: [source.name, "secret"]})
      assert {:ok, second_membership} = UserChannels.get_by_user_pid_and_channel_name(second.pid, channel.name)
      assert second_membership.modes == []
    end)

    assert view.channel["creator"] == "east.example"
  end

  test "an existing local channel with a different identity cannot admit against remote authority" do
    source = build(:channel, name: "#conflict")
    publish(source)

    Memento.transaction!(fn ->
      user = insert(:user, nick: "Viewer")
      local = Channels.create(%{name: source.name, created_at: source.created_at, creator: "irc.test"})
      assert :ok = Join.handle(user, %Message{command: "JOIN", params: [source.name]})
      assert {:error, :user_channel_not_found} = UserChannels.get_by_user_pid_and_channel_name(user.pid, source.name)
      assert {:ok, ^local} = Channels.get_by_name(source.name)
      assert_sent_message_contains(user.pid, ~r/ 437 Viewer #conflict /)
    end)
  end

  test "effective network bans block JOIN and network exceptions allow it" do
    source = build(:channel, name: "#banned")
    ban = record("b", "*!*@blocked.test")
    exception = record("e", "*!*@blocked.test")
    publish(source, lists: [ban])

    Memento.transaction!(fn ->
      user = insert(:user, nick: "Blocked", hostname: "blocked.test")
      assert :ok = Join.handle(user, %Message{command: "JOIN", params: [source.name]})
      assert {:error, :user_channel_not_found} = UserChannels.get_by_user_pid_and_channel_name(user.pid, source.name)
      assert {:error, :channel_not_found} = Channels.get_by_name(source.name)
      assert_sent_message_contains(user.pid, ~r/ 474 Blocked #banned /)
    end)

    republish(source, lists: [ban, exception])

    Memento.transaction!(fn ->
      user = insert(:user, nick: "Allowed", hostname: "blocked.test")
      assert :ok = Join.handle(user, %Message{command: "JOIN", params: [source.name]})
      assert {:ok, _membership} = UserChannels.get_by_user_pid_and_channel_name(user.pid, source.name)
    end)
  end

  test "network invite exception authorizes +i while remote members count toward +l" do
    invited = build(:channel, name: "#invex", modes: [:i])
    publish(invited, lists: [record("I", "*!*@invited.test")])

    Memento.transaction!(fn ->
      user = insert(:user, nick: "Invitee", hostname: "invited.test")
      assert :ok = Join.handle(user, %Message{command: "JOIN", params: [invited.name]})
      assert {:ok, _membership} = UserChannels.get_by_user_pid_and_channel_name(user.pid, invited.name)
    end)

    limited = build(:channel, name: "#full", modes: [{:l, "1"}])
    remote_member = %{origin: "east.example", member: %{"uid" => String.duplicate("a", 32)}, effective_modes: []}
    republish(limited, members: [remote_member])

    Memento.transaction!(fn ->
      user = insert(:user, nick: "Late")
      assert :ok = Join.handle(user, %Message{command: "JOIN", params: [limited.name]})
      assert {:error, :user_channel_not_found} = UserChannels.get_by_user_pid_and_channel_name(user.pid, limited.name)
      assert {:error, :channel_not_found} = Channels.get_by_name(limited.name)
      assert_sent_message_contains(user.pid, ~r/ 471 Late #full /)
    end)
  end

  test "remote recent membership counts toward the selected +j admission window" do
    source = build(:channel, name: "#throttled", modes: [{:j, "1:60"}])
    uid = String.duplicate("a", 32)
    remote_user = build(:user, nick: "Remote", hostname: "east.example")

    member = %{
      origin: "east.example",
      member: %{"uid" => uid, "joined_at" => DateTime.to_iso8601(DateTime.utc_now())},
      user: UserPayload.from_local(remote_user, uid),
      effective_modes: []
    }

    publish(source, members: [member])

    Memento.transaction!(fn ->
      user = insert(:user, nick: "Throttled")
      assert :ok = Join.handle(user, %Message{command: "JOIN", params: [source.name]})
      assert {:error, :user_channel_not_found} = UserChannels.get_by_user_pid_and_channel_name(user.pid, source.name)
      assert_sent_message_contains(user.pid, ~r/ 477 Throttled #throttled /)
    end)

    old_member = put_in(member, [:member, "joined_at"], DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -120)))
    republish(source, members: [old_member])

    Memento.transaction!(fn ->
      user = insert(:user, nick: "Admitted")
      assert :ok = Join.handle(user, %Message{command: "JOIN", params: [source.name]})
      assert {:ok, _membership} = UserChannels.get_by_user_pid_and_channel_name(user.pid, source.name)
    end)
  end

  test "later remote mode and topic changes update an aligned adoption for the next JOIN" do
    source = build(:channel, name: "#evolving")
    previous = publish(source)

    first =
      Memento.transaction!(fn ->
        user = insert(:user, nick: "First")
        assert :ok = Join.handle(user, %Message{command: "JOIN", params: [source.name]})
        user
      end)

    topic = build(:channel_topic, text: "Updated topic", setter: "Remote!user@east.example")
    updated_source = build(:channel, name: source.name, created_at: source.created_at, modes: [:n], topic: topic)
    current = republish(updated_source, [])
    key = source.name_key
    assert %{} = ChannelReconciler.reconcile(%{key => previous}, %{key => current}, "irc.test")
    assert_sent_message_contains(first.pid, ~r/:irc\.test MODE #evolving \+n\r\n/)
    assert_sent_message_contains(first.pid, ~r/:irc\.test TOPIC #evolving :Updated topic\r\n/)

    Memento.transaction!(fn ->
      assert {:ok, local} = Channels.get_by_name(source.name)
      assert local.modes == [:n]
      assert local.topic.text == "Updated topic"
      assert local.created_at == source.created_at

      user = insert(:user, nick: "Second")
      assert :ok = Join.handle(user, %Message{command: "JOIN", params: [source.name]})
      assert {:ok, membership} = UserChannels.get_by_user_pid_and_channel_name(user.pid, source.name)
      assert membership.modes == []
    end)
  end

  test "a later remote topic removal and parameter change notify existing local members" do
    topic = build(:channel_topic, text: "Initial topic", setter: "Remote!user@east.example")
    source = build(:channel, name: "#replaced", modes: [{:l, "4"}], topic: topic)
    previous = publish(source)

    user =
      Memento.transaction!(fn ->
        user = insert(:user, nick: "Member")
        assert :ok = Join.handle(user, %Message{command: "JOIN", params: [source.name]})
        user
      end)

    updated_source = build(:channel, name: source.name, created_at: source.created_at, modes: [{:l, "5"}], topic: nil)
    current = republish(updated_source, [])
    key = source.name_key
    assert %{} = ChannelReconciler.reconcile(%{key => previous}, %{key => current}, "irc.test")
    assert_sent_message_contains(user.pid, ~r/:irc\.test MODE #replaced -l\+l 5\r\n/)
    assert_sent_message_contains(user.pid, ~r/:irc\.test TOPIC #replaced :\r\n/)
  end

  test "an older remote creation replaces local privileges, lists and invitations atomically" do
    remote_topic = build(:channel_topic, text: "Remote topic", setter: "Remote!user@east.example")

    source =
      build(:channel,
        name: "#collision",
        created_at: DateTime.add(DateTime.utc_now(), -120),
        modes: [:n],
        topic: remote_topic
      )

    view = publish(source)

    {operator, voiced, local} =
      Memento.transaction!(fn ->
        operator = insert(:user, nick: "Operator")
        voiced = insert(:user, nick: "Voiced")
        invitee = insert(:user, nick: "Invitee")
        local_topic = build(:channel_topic, text: "Local topic")

        local =
          insert(:channel,
            name: source.name,
            created_at: DateTime.add(source.created_at, 60),
            modes: [:i],
            topic: local_topic
          )

        insert(:user_channel, user: operator, channel: local, modes: [:o])
        insert(:user_channel, user: voiced, channel: local, modes: [:v])
        insert(:channel_ban, channel: local, mask: "*!*@blocked.test")
        insert(:channel_except, channel: local, mask: "*!*@excepted.test")
        insert(:channel_invex, channel: local, mask: "*!*@invited.test")
        insert(:channel_invite, user: invitee, channel: local)
        {operator, voiced, local}
      end)

    key = source.name_key
    assert %{^key => prior_memberships} = ChannelReconciler.reconcile(%{}, %{key => view}, "irc.test")
    assert Enum.any?(prior_memberships, &(:o in &1.modes))

    Memento.transaction!(fn ->
      assert {:ok, channel} = Channels.get_by_name(local.name)
      assert channel.created_at == source.created_at
      assert channel.modes == [:n]
      assert channel.topic.text == "Remote topic"
      assert %ChannelIdentity{creator: "east.example"} = Memento.Query.read(ChannelIdentity, local.name_key)
      assert {:ok, operator_membership} = UserChannels.get_by_user_pid_and_channel_name(operator.pid, local.name)
      assert {:ok, voiced_membership} = UserChannels.get_by_user_pid_and_channel_name(voiced.pid, local.name)
      assert operator_membership.modes == []
      assert voiced_membership.modes == []
      assert ChannelBans.get_by_channel_name_key(local.name_key) == []
      assert ChannelExcepts.get_by_channel_name_key(local.name_key) == []
      assert ChannelInvexes.get_by_channel_name_key(local.name_key) == []
      assert ChannelInvites.get_by_channel_name_key(local.name_key) == []

      newcomer = insert(:user, nick: "Newcomer")
      assert :ok = Join.handle(newcomer, %Message{command: "JOIN", params: [local.name]})
      assert {:ok, membership} = UserChannels.get_by_user_pid_and_channel_name(newcomer.pid, local.name)
      assert membership.modes == []
    end)

    assert_sent_message_contains(operator.pid, ~r/:irc\.test MODE #collision -o Operator\r\n/)
    assert_sent_message_contains(voiced.pid, ~r/:irc\.test MODE #collision -v Voiced\r\n/)
    assert_sent_message_contains(operator.pid, ~r/:irc\.test MODE #collision -b \*!\*@blocked\.test\r\n/)
    assert_sent_message_contains(operator.pid, ~r/:irc\.test TOPIC #collision :Remote topic\r\n/)

    projected =
      ChannelState.snapshot(
        %{operator.pid => %{uid: String.duplicate("1", 32)}, voiced.pid => %{uid: String.duplicate("2", 32)}},
        "irc.test"
      )

    assert [%{"creator" => "east.example", "created_at" => created_at}] = projected.channels
    assert created_at == DateTime.to_iso8601(source.created_at)
    assert Enum.all?(projected.members, &(&1["modes"] == []))
    assert projected.lists == []
    assert projected.invites == []
  end

  test "a newer remote creation cannot replace an older local channel" do
    created_at = DateTime.add(DateTime.utc_now(), -120)

    local =
      Memento.transaction!(fn ->
        channel = insert(:channel, name: "#local-wins", created_at: created_at, modes: [:i])
        operator = insert(:user, nick: "LocalOp")
        insert(:user_channel, user: operator, channel: channel, modes: [:o])
        channel
      end)

    newer = build(:channel, name: local.name, created_at: DateTime.add(created_at, 60), modes: [:n])
    view = publish(newer)
    assert %{} = ChannelReconciler.reconcile(%{}, %{local.name_key => view}, "irc.test")

    Memento.transaction!(fn ->
      assert {:ok, ^local} = Channels.get_by_name(local.name)
      assert nil == Memento.Query.read(ChannelIdentity, local.name_key)
      assert [%{modes: [:o]}] = UserChannels.get_by_channel_name(local.name)
    end)
  end

  test "the coordinator reconciles an older creation after the remote snapshot commits" do
    remote = build(:channel, name: "#hub-collision", created_at: DateTime.add(DateTime.utc_now(), -120), modes: [:u])

    {local, operator} =
      Memento.transaction!(fn ->
        local = insert(:channel, name: remote.name, created_at: DateTime.add(remote.created_at, 60), modes: [:i])
        operator = insert(:user, nick: "OldOp")
        insert(:user_channel, user: operator, channel: local, modes: [:o])
        {local, operator}
      end)

    key = local.name_key
    local_channels = %{key => ChannelPayload.from_local(local, "irc.test")}
    epoch = String.duplicate("f", 32)
    uid = String.duplicate("a", 32)
    replica = Replica.new()

    begin_frame = %{
      "type" => "snapshot_begin",
      "origin" => "east.example",
      "epoch" => epoch,
      "cursor" => 0,
      "count" => 1,
      "channel_count" => 1,
      "member_count" => 1,
      "list_count" => 0,
      "invite_count" => 0
    }

    payload = ChannelPayload.from_local(remote, "east.example")
    user = build(:user, nick: "Remote", hostname: "east.example") |> UserPayload.from_local(uid)

    member = %{
      "channel" => remote.name,
      "uid" => uid,
      "modes" => [],
      "joined_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    user_frame = %{"type" => "snapshot_user", "origin" => "east.example", "epoch" => epoch, "user" => user}
    channel_frame = %{"type" => "snapshot_channel", "origin" => "east.example", "epoch" => epoch, "channel" => payload}
    member_frame = %{"type" => "snapshot_member", "origin" => "east.example", "epoch" => epoch, "member" => member}
    {:ok, replica} = Replica.apply(replica, begin_frame)
    {:ok, replica} = Replica.apply(replica, user_frame)
    {:ok, replica} = Replica.apply(replica, channel_frame)
    {:ok, replica} = Replica.apply(replica, member_frame)

    state = %Hub.State{
      id: "irc.test",
      network: "test-network",
      replays: Hub.ReplayCaches.new(),
      local_epoch: UserPayload.new_uid(),
      links: %{"east.example" => self()},
      routes: %{"east.example" => %{via: "east.example", epoch: epoch}},
      replica: replica,
      local_channels: local_channels,
      channel_authorities: ChannelAuthority.select("irc.test", local_channels, %{}),
      channel_view: ChannelView.select("irc.test", local_channels, Replica.new()),
      indexes: %Hub.Indexes{}
    }

    end_frame = %{"type" => "snapshot_end", "origin" => "east.example", "epoch" => epoch}

    assert {:reply, :ok, updated} =
             Hub.handle_call({:remote_frame, "east.example", self(), end_frame}, {self(), make_ref()}, state)

    assert updated.channel_view[key].origin == "east.example"
    assert {:ok, %{origin: "east.example"}} = ChannelAuthority.get(updated.channel_authorities, local.name)

    Memento.transaction!(fn ->
      assert {:ok, channel} = Channels.get_by_name(local.name)
      assert channel.created_at == remote.created_at
      assert channel.modes == [:u]
      assert %ChannelIdentity{creator: "east.example"} = Memento.Query.read(ChannelIdentity, key)
    end)

    assert_sent_message_contains(operator.pid, ~r/:irc\.test MODE #hub-collision -o OldOp\r\n/)
    assert_sent_messages_count_containing(operator.pid, ~r/ JOIN #hub-collision\r\n/, 0)
  end

  defp publish(channel, options \\ []) do
    table = ChannelDirectory.create()
    view = view(channel, options)
    ChannelDirectory.sync(table, %{}, %{channel.name_key => view})
    view
  end

  defp republish(channel, options) do
    table = :ets.whereis(:elixircd_server_link_channels)
    old = Map.new(ChannelDirectory.all(), &{CaseMapping.normalize(&1.channel["name"]), &1})
    view = view(channel, options)
    ChannelDirectory.sync(table, old, Map.put(old, channel.name_key, view))
    view
  end

  defp view(channel, options) do
    %ChannelView{
      origin: "east.example",
      channel: ChannelPayload.from_local(channel, "east.example"),
      remote_present: true,
      remote_members: Keyword.get(options, :members, []),
      remote_lists: Keyword.get(options, :lists, []),
      remote_invites: []
    }
  end

  defp record(kind, mask), do: %{effective: true, entry: %{"kind" => kind, "mask" => mask}}
end
