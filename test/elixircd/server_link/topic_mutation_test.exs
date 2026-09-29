defmodule ElixIRCd.ServerLink.TopicMutationTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.Frame
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.Projector
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.Route
  alias ElixIRCd.ServerLink.TopicMutation
  alias ElixIRCd.ServerLink.TopicMutation.Pending
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.RegisteredChannel.Settings

  @origin "east.example"
  @local_id "irc.test"
  @uid String.duplicate("a", 32)

  test "the selected authority applies a remote operator's topic after commit" do
    {channel, viewer, replica, view, request} = fixture(["o"])

    assert {:ok, updated} = TopicMutation.apply(request, replica, view, @local_id)
    assert updated.topic.text == "Network topic"
    assert String.starts_with?(updated.topic.setter, "Remote!")

    Memento.transaction!(fn ->
      assert Memento.Query.read(Channel, channel.name_key).topic == updated.topic
    end)

    assert_sent_message_contains(viewer.pid, ~r/:Remote!.* TOPIC #network-topic :Network topic\r\n/)
  end

  test "a remote member without operator status cannot change a +t topic" do
    {channel, viewer, replica, view, request} = fixture([])

    assert {:error, :operator_required} = TopicMutation.apply(request, replica, view, @local_id)
    Memento.transaction!(fn -> assert Memento.Query.read(Channel, channel.name_key).topic == nil end)
    assert_sent_messages_amount(viewer.pid, 0)
  end

  test "the authority rejects stale origins and unknown senders" do
    {_channel, _viewer, replica, view, request} = fixture(["o"])
    assert {:error, :stale_authority} = TopicMutation.apply(request, replica, %{view | origin: @origin}, @local_id)
    assert {:error, :unknown_sender} = TopicMutation.apply(request, Replica.new(), view, @local_id)
  end

  test "ChanServ TOPICLOCK and unsafe text remain protected from remote requests" do
    {channel, viewer, replica, view, request} = fixture(["o"])

    Memento.transaction!(fn ->
      insert(:registered_channel,
        name: channel.name,
        founder: "founder",
        settings: Settings.new(%{topiclock: true})
      )
    end)

    assert {:error, :topic_locked} = TopicMutation.apply(request, replica, view, @local_id)

    assert {:error, :invalid_topic} =
             TopicMutation.apply(%{request | text: "unsafe\r\nline"}, replica, view, @local_id)

    Memento.transaction!(fn -> assert Memento.Query.read(Channel, channel.name_key).topic == nil end)
    assert_sent_messages_amount(viewer.pid, 0)
  end

  test "the authority accepts an authenticated TOPIC frame and routes its result" do
    {channel, viewer, replica, view, request} = fixture(["o"])
    epoch = UserPayload.new_uid()
    state = routing_state(@local_id, replica, %{channel.name_key => view}, @origin, epoch)
    frame = request_frame(request, epoch)

    assert {:reply, :ok, updated} = Hub.handle_call({:remote_frame, @origin, self(), frame}, self(), state)
    assert updated.topic_pending == %{}
    assert_receive {:link_frame, %{"type" => "topic_result", "id" => id, "code" => "ok"} = result}
    assert id == frame["id"]
    assert :ok = Frame.validate(result)
    assert_sent_message_contains(viewer.pid, ~r/:Remote!.* TOPIC #network-topic :Network topic\r\n/)

    forged = %{frame | "epoch" => UserPayload.new_uid()}

    assert {:reply, {:error, :unknown_route}, ^state} =
             Hub.handle_call({:remote_frame, @origin, self(), forged}, self(), state)
  end

  test "a TOPIC result must match the pending UID, authority, epoch and channel" do
    {_channel, viewer, _replica, _view, _request} = fixture(["o"])
    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, uid} = Projector.uid_for_pid(projector, viewer.pid)
    epoch = UserPayload.new_uid()
    id = UserPayload.new_uid()
    pending = %Pending{uid: uid, authority: @origin, authority_epoch: epoch, channel: "#network-topic"}

    state =
      routing_state(@local_id, Replica.new(), %{}, @origin, epoch)
      |> Map.put(:projector, projector)
      |> Map.put(:topic_pending, %{id => pending})

    result = %{
      "type" => "topic_result",
      "origin" => @origin,
      "epoch" => epoch,
      "to_origin" => @local_id,
      "to_uid" => uid,
      "channel" => "#network-topic",
      "id" => id,
      "code" => "operator_required",
      "ttl" => 64
    }

    assert {:reply, {:error, :invalid_topic_result}, ^state} =
             Hub.handle_call(
               {:remote_frame, @origin, self(), %{result | "to_uid" => UserPayload.new_uid()}},
               self(),
               state
             )

    assert {:reply, :ok, updated} = Hub.handle_call({:remote_frame, @origin, self(), result}, self(), state)
    assert updated.topic_pending == %{}
    assert_sent_message_contains(viewer.pid, ~r/482 Viewer #network-topic :You're not a channel operator\r\n/)
    assert {:reply, :ok, ^updated} = Hub.handle_call({:remote_frame, @origin, self(), result}, self(), updated)
  end

  test "an unanswered TOPIC request expires with a client error" do
    {_channel, viewer, _replica, _view, _request} = fixture(["o"])
    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, uid} = Projector.uid_for_pid(projector, viewer.pid)
    id = UserPayload.new_uid()
    pending = %Pending{uid: uid, authority: @origin, authority_epoch: UserPayload.new_uid(), channel: "#network-topic"}

    state =
      routing_state(@local_id, Replica.new(), %{}, @origin, UserPayload.new_uid())
      |> Map.put(:projector, projector)
      |> Map.put(:topic_pending, %{id => pending})

    assert {:noreply, updated} = Hub.handle_info({:topic_request_expired, id}, state)
    assert updated.topic_pending == %{}
    assert_sent_message_contains(viewer.pid, ~r/437 Viewer #network-topic :Channel topic is temporarily unavailable/)
  end

  test "route loss rejects an outstanding TOPIC request before its timeout" do
    {_channel, viewer, _replica, _view, _request} = fixture(["o"])
    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, uid} = Projector.uid_for_pid(projector, viewer.pid)
    epoch = UserPayload.new_uid()
    id = UserPayload.new_uid()
    pending = %Pending{uid: uid, authority: @origin, authority_epoch: epoch, channel: "#network-topic"}

    state =
      routing_state(@local_id, Replica.new(), %{}, @origin, epoch)
      |> Map.put(:projector, projector)
      |> Map.put(:topic_pending, %{id => pending})

    down = %{"type" => "route_down", "origin" => @origin, "epoch" => epoch}
    assert :ok = Frame.validate(down)
    assert {:reply, :ok, after_drop} = Hub.handle_call({:remote_frame, @origin, self(), down}, self(), state)
    assert after_drop.topic_pending == %{}
    assert_sent_message_contains(viewer.pid, ~r/437 Viewer #network-topic :Channel topic is temporarily unavailable/)
    assert {:noreply, ^after_drop} = Hub.handle_info({:topic_request_expired, id}, after_drop)
  end

  test "a local TOPIC request uses a typed pending entry and validates membership" do
    {channel, viewer, _replica, _view, _request} = fixture(["o"])
    epoch = UserPayload.new_uid()
    uid = UserPayload.new_uid()

    remote_view = %ChannelView{
      origin: @origin,
      channel: ChannelPayload.from_local(channel, @origin),
      remote_present: true
    }

    state = routing_state(@local_id, Replica.new(), %{channel.name_key => remote_view}, @origin, epoch)

    assert {:noreply, updated} =
             Hub.handle_info({:topic_request_ready, viewer.pid, uid, @origin, channel.name, "new topic", 0}, state)

    assert_receive {:link_frame, %{"type" => "topic_request", "from_uid" => ^uid, "id" => id} = frame}
    assert :ok = Frame.validate(frame)

    assert %Pending{uid: ^uid, authority: @origin, authority_epoch: ^epoch, channel: "#network-topic"} =
             updated.topic_pending[id]

    assert {:noreply, ^state} =
             Hub.handle_info(
               {:topic_request_ready, viewer.pid, uid, "other.example", channel.name, "new topic", 0},
               state
             )

    assert_sent_message_contains(viewer.pid, ~r/437 Viewer #network-topic :Channel topic is temporarily unavailable/)
  end

  test "a relay forwards only an authenticated sender and decrements the TTL" do
    source_epoch = UserPayload.new_uid()
    authority_epoch = UserPayload.new_uid()
    remote = build(:user, nick: "Remote") |> UserPayload.from_local(@uid)
    replica = %Replica{users: %{{@origin, @uid} => remote}}

    state =
      routing_state("middle.example", replica, %{}, @origin, source_epoch)
      |> Map.put(:links, %{@origin => self(), "west.example" => self()})
      |> Map.update!(:routes, fn routes ->
        Map.put(routes, "west.example", %{via: "west.example", epoch: authority_epoch})
      end)

    frame =
      request_frame(
        %TopicMutation.Request{origin: @origin, uid: @uid, channel: "#network-topic", text: "new"},
        source_epoch
      )
      |> Map.put("to_origin", "west.example")

    assert {:reply, :ok, ^state} = Hub.handle_call({:remote_frame, @origin, self(), frame}, self(), state)
    assert_receive {:link_frame, %{"type" => "topic_request", "ttl" => 63, "id" => id}}
    assert id == frame["id"]

    forged = %{frame | "from_uid" => UserPayload.new_uid()}

    assert {:reply, {:error, :unknown_sender}, ^state} =
             Hub.handle_call({:remote_frame, @origin, self(), forged}, self(), state)

    refute_received {:link_frame, _}

    result = %{
      "type" => "topic_result",
      "origin" => "west.example",
      "epoch" => authority_epoch,
      "to_origin" => @origin,
      "to_uid" => @uid,
      "channel" => "#network-topic",
      "id" => frame["id"],
      "code" => "ok",
      "ttl" => 64
    }

    assert {:reply, :ok, ^state} = Hub.handle_call({:remote_frame, "west.example", self(), result}, self(), state)
    assert_receive {:link_frame, %{"type" => "topic_result", "ttl" => 63, "id" => ^id}}
  end

  defp routing_state(id, replica, channel_view, remote, epoch) do
    %Hub.State{
      id: id,
      network: "test-network",
      replays: Hub.ReplayCaches.new(),
      local_epoch: UserPayload.new_uid(),
      local_cursor: 0,
      local_channels: %{},
      replica: replica,
      channel_view: channel_view,
      indexes: %Hub.Indexes{},
      projector: nil,
      links: %{remote => self()},
      routes: %{remote => %Route{via: remote, epoch: epoch, path: [remote, id]}},
      topic_pending: %{},
      mode_pending: %{},
      kick_pending: %{},
      direct_pending: %{}
    }
  end

  defp request_frame(request, epoch) do
    %{
      "type" => "topic_request",
      "origin" => request.origin,
      "epoch" => epoch,
      "from_uid" => request.uid,
      "to_origin" => @local_id,
      "channel" => request.channel,
      "text" => request.text,
      "id" => UserPayload.new_uid(),
      "ttl" => 64
    }
  end

  defp fixture(status) do
    {channel, viewer} =
      Memento.transaction!(fn ->
        channel = insert(:channel, name: "#network-topic", topic: nil, modes: [:t])
        viewer = insert(:user, nick: "Viewer")
        insert(:user_channel, user: viewer, channel: channel)
        {channel, viewer}
      end)

    remote = build(:user, nick: "Remote") |> UserPayload.from_local(@uid)
    replica = %Replica{users: %{{@origin, @uid} => remote}}

    view = %ChannelView{
      origin: @local_id,
      channel: ChannelPayload.from_local(channel, @local_id),
      remote_present: true,
      remote_members: [%{origin: @origin, member: %{"uid" => @uid}, user: remote, effective_modes: status}]
    }

    request = %TopicMutation.Request{origin: @origin, uid: @uid, channel: channel.name, text: "Network topic"}
    {channel, viewer, replica, view, request}
  end
end
