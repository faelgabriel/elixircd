defmodule ElixIRCd.ServerLink.ModeMutationTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.ChannelView.RemoteMember
  alias ElixIRCd.ServerLink.Frame
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.ModeMutation
  alias ElixIRCd.ServerLink.ModeMutation.Outbound
  alias ElixIRCd.ServerLink.ModeMutation.Pending
  alias ElixIRCd.ServerLink.Projector
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.Route
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Tables.ChannelExcept
  alias ElixIRCd.Tables.ChannelInvex
  alias ElixIRCd.Tables.RegisteredChannel.Settings
  alias ElixIRCd.Utils.Protocol

  @origin "east.example"
  @local_id "irc.test"
  @uid String.duplicate("a", 32)

  test "the selected authority applies a remote operator's metadata modes after commit" do
    {channel, viewer, replica, view, request} = fixture(["o"])

    assert {:ok, updated, [{:add, :n}, {:add, :t}]} = ModeMutation.apply(request, replica, view, @local_id)
    assert :n in updated.modes and :t in updated.modes
    Memento.transaction!(fn -> assert Memento.Query.read(Channel, channel.name_key).modes == updated.modes end)
    assert_sent_message_contains(viewer.pid, ~r/:Remote!.* MODE #network-mode \+nt\r\n/)
  end

  test "the authority rejects non-operators and status changes without mutating the channel" do
    {channel, viewer, replica, view, request} = fixture([])

    assert {:error, :operator_required} = ModeMutation.apply(request, replica, view, @local_id)

    assert {:error, :unsupported_mode} =
             ModeMutation.apply(%{request | mode_string: "+o", values: ["Viewer"]}, replica, view, @local_id)

    Memento.transaction!(fn -> assert Memento.Query.read(Channel, channel.name_key).modes == [] end)
    assert_sent_messages_amount(viewer.pid, 0)
  end

  test "the authority rejects a stale channel identity" do
    {_channel, _viewer, replica, view, request} = fixture(["o"])
    assert {:error, :stale_authority} = ModeMutation.apply(request, replica, %{view | origin: @origin}, @local_id)
  end

  test "a registered channel and invalid parameters cannot be changed by a remote request" do
    {channel, _viewer, replica, view, request} = fixture(["o"])

    assert {:error, :invalid_mode} =
             ModeMutation.apply(%{request | mode_string: "+l", values: ["bad"]}, replica, view, @local_id)

    assert {:error, :invalid_mode} =
             ModeMutation.apply(%{request | mode_string: "+n", values: ["ignored"]}, replica, view, @local_id)

    Memento.transaction!(fn ->
      insert(:registered_channel,
        name: channel.name,
        founder: "founder",
        settings: Settings.new(%{})
      )
    end)

    assert {:error, :registered_channel} = ModeMutation.apply(request, replica, view, @local_id)
    Memento.transaction!(fn -> assert Memento.Query.read(Channel, channel.name_key).modes == [] end)
  end

  test "parameter metadata modes are applied without creating a local user for the remote actor" do
    {channel, _viewer, replica, view, request} = fixture(["o"])
    request = %{request | mode_string: "+kl", values: ["secret", "12"]}

    assert {:ok, updated, [{:add, {:k, "secret"}}, {:add, {:l, "12"}}]} =
             ModeMutation.apply(request, replica, view, @local_id)

    assert {:k, "secret"} in updated.modes
    assert {:l, "12"} in updated.modes
    Memento.transaction!(fn -> assert Memento.Query.read(Channel, channel.name_key).modes == updated.modes end)
  end

  test "the authority persists remote ban, exception and invite-exception modes with the actor's mask" do
    {channel, viewer, replica, view, request} = fixture(["o"])
    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    expected_setter = replica.users[{@origin, @uid}] |> UserPayload.public_view() |> Protocol.user_mask()
    masks = ["bad!*@*", "$a:trusted", "invited!*@*"]
    adding = %{request | mode_string: "+beI", values: masks}

    assert {:ok, _updated, [{:add, {:b, "bad!*@*"}}, {:add, {:e, "$a:trusted"}}, {:add, {:I, "invited!*@*"}}]} =
             ModeMutation.apply(adding, replica, view, @local_id)

    Memento.transaction!(fn ->
      assert [%ChannelBan{setter: ^expected_setter}] =
               Memento.Query.match(ChannelBan, {channel.name_key, :_, :_, :_, :_})

      assert [%ChannelExcept{setter: ^expected_setter}] =
               Memento.Query.match(ChannelExcept, {channel.name_key, :_, :_, :_, :_})

      assert [%ChannelInvex{setter: ^expected_setter}] =
               Memento.Query.match(ChannelInvex, {channel.name_key, :_, :_, :_, :_})
    end)

    snapshot = Projector.refresh_snapshot(projector)

    assert Enum.sort(Enum.map(snapshot.lists, &{&1["kind"], &1["mask"]})) ==
             Enum.sort([{"b", "bad!*@*"}, {"e", "$a:trusted"}, {"I", "invited!*@*"}])

    assert_sent_message_contains(
      viewer.pid,
      ~r/:Remote!.* MODE #network-mode \+beI bad!\*@\* \$a:trusted invited!\*@\*/
    )

    removing = %{request | mode_string: "-beI", values: masks}

    assert {:ok, _updated, [{:remove, {:b, "bad!*@*"}}, {:remove, {:e, "$a:trusted"}}, {:remove, {:I, "invited!*@*"}}]} =
             ModeMutation.apply(removing, replica, view, @local_id)

    Memento.transaction!(fn ->
      assert Memento.Query.match(ChannelBan, {channel.name_key, :_, :_, :_, :_}) == []
      assert Memento.Query.match(ChannelExcept, {channel.name_key, :_, :_, :_, :_}) == []
      assert Memento.Query.match(ChannelInvex, {channel.name_key, :_, :_, :_, :_}) == []
    end)

    assert Projector.refresh_snapshot(projector).lists == []
  end

  test "invalid or unsupported list changes cannot partially apply a MODE batch" do
    {channel, _viewer, replica, view, request} = fixture(["o"])

    assert {:error, :unsupported_mode} =
             ModeMutation.apply(
               %{request | mode_string: "+bo", values: ["bad!*@*", "Viewer"]},
               replica,
               view,
               @local_id
             )

    assert {:error, :unsupported_mode} =
             ModeMutation.apply(%{request | mode_string: "+b", values: ["bad name"]}, replica, view, @local_id)

    Memento.transaction!(fn ->
      assert Memento.Query.match(ChannelBan, {channel.name_key, :_, :_, :_, :_}) == []
    end)
  end

  test "authenticated mode frames route to the selected authority and return one result" do
    {channel, viewer, replica, view, request} = fixture(["o"])
    epoch = UserPayload.new_uid()
    state = routing_state(replica, %{channel.name_key => view}, epoch)
    frame = request_frame(request, epoch)

    assert {:reply, :ok, updated} = Hub.handle_call({:remote_frame, @origin, self(), frame}, self(), state)
    assert updated.mode_pending == %{}
    assert_receive {:link_frame, %{"type" => "mode_result", "code" => "ok", "id" => id} = result}
    assert id == frame["id"]
    assert :ok = Frame.validate(result)
    assert_sent_message_contains(viewer.pid, ~r/:Remote!.* MODE #network-mode \+nt\r\n/)

    forged = %{frame | "epoch" => UserPayload.new_uid()}

    assert {:reply, {:error, :unknown_route}, ^state} =
             Hub.handle_call({:remote_frame, @origin, self(), forged}, self(), state)
  end

  test "a local mode request keeps typed pending state and rejects mismatched results" do
    {channel, viewer, _replica, _view, _request} = fixture(["o"])
    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, uid} = Projector.uid_for_pid(projector, viewer.pid)
    epoch = UserPayload.new_uid()

    remote_view = %ChannelView{
      origin: @origin,
      channel: ChannelPayload.from_local(channel, @origin),
      remote_present: true
    }

    state =
      routing_state(Replica.new(), %{channel.name_key => remote_view}, epoch)
      |> Map.put(:projector, projector)

    outbound = %Outbound{
      sender_pid: viewer.pid,
      authority: @origin,
      channel: channel.name,
      mode_string: "+nt",
      values: []
    }

    assert {:noreply, pending_state} = Hub.handle_info({:mode_request_ready, outbound, uid, 0}, state)
    assert_receive {:link_frame, %{"type" => "mode_request", "id" => id} = sent}
    assert :ok = Frame.validate(sent)
    assert %Pending{uid: ^uid, authority: @origin, authority_epoch: ^epoch} = pending_state.mode_pending[id]

    result = %{
      "type" => "mode_result",
      "origin" => @origin,
      "epoch" => epoch,
      "to_origin" => @local_id,
      "to_uid" => uid,
      "channel" => channel.name,
      "id" => id,
      "code" => "operator_required",
      "ttl" => 64
    }

    assert {:reply, {:error, :invalid_mode_result}, ^pending_state} =
             Hub.handle_call(
               {:remote_frame, @origin, self(), %{result | "to_uid" => UserPayload.new_uid()}},
               self(),
               pending_state
             )

    assert {:reply, :ok, cleared} = Hub.handle_call({:remote_frame, @origin, self(), result}, self(), pending_state)
    assert cleared.mode_pending == %{}
    assert_sent_message_contains(viewer.pid, ~r/482 Viewer #network-mode :You're not a channel operator/)
    assert {:reply, :ok, ^cleared} = Hub.handle_call({:remote_frame, @origin, self(), result}, self(), cleared)
  end

  test "an intermediate server forwards only authenticated requests and results within their TTL" do
    {_channel, _viewer, replica, _view, request} = fixture(["o"])
    west = "west.example"
    west_epoch = UserPayload.new_uid()
    east_epoch = UserPayload.new_uid()

    state =
      routing_state(replica, %{}, east_epoch)
      |> Map.put(:id, "middle.example")
      |> Map.put(:links, %{@origin => self(), west => self()})
      |> Map.put(:routes, %{
        @origin => %{via: @origin, epoch: east_epoch},
        west => %{via: west, epoch: west_epoch}
      })

    frame = request_frame(request, east_epoch) |> Map.put("to_origin", west) |> Map.put("ttl", 2)
    assert :ok = Frame.validate(frame)
    assert {:reply, :ok, ^state} = Hub.handle_call({:remote_frame, @origin, self(), frame}, self(), state)
    assert_receive {:link_frame, %{"type" => "mode_request", "ttl" => 1, "id" => id}}
    assert id == frame["id"]

    assert {:reply, {:error, :unknown_route}, ^state} =
             Hub.handle_call({:remote_frame, west, self(), frame}, self(), state)

    assert {:reply, :ok, ^state} =
             Hub.handle_call({:remote_frame, @origin, self(), %{frame | "ttl" => 1}}, self(), state)

    refute_receive {:link_frame, _}

    result = %{
      "type" => "mode_result",
      "origin" => west,
      "epoch" => west_epoch,
      "to_origin" => @origin,
      "to_uid" => @uid,
      "channel" => request.channel,
      "id" => frame["id"],
      "code" => "ok",
      "ttl" => 2
    }

    assert :ok = Frame.validate(result)
    assert {:reply, :ok, ^state} = Hub.handle_call({:remote_frame, west, self(), result}, self(), state)
    assert_receive {:link_frame, %{"type" => "mode_result", "ttl" => 1, "id" => ^id}}
  end

  test "an unanswered request expires and clears its typed pending record" do
    {channel, viewer, _replica, _view, _request} = fixture(["o"])
    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, uid} = Projector.uid_for_pid(projector, viewer.pid)
    epoch = UserPayload.new_uid()

    remote_view = %ChannelView{
      origin: @origin,
      channel: ChannelPayload.from_local(channel, @origin),
      remote_present: true
    }

    state =
      routing_state(Replica.new(), %{channel.name_key => remote_view}, epoch)
      |> Map.put(:projector, projector)

    outbound = %Outbound{
      sender_pid: viewer.pid,
      authority: @origin,
      channel: channel.name,
      mode_string: "+n",
      values: []
    }

    assert {:noreply, pending_state} = Hub.handle_info({:mode_request_ready, outbound, uid, 0}, state)
    assert_receive {:link_frame, %{"type" => "mode_request", "id" => id}}
    assert {:noreply, cleared} = Hub.handle_info({:mode_request_expired, id}, pending_state)
    assert cleared.mode_pending == %{}
    assert_sent_message_contains(viewer.pid, ~r/437 Viewer #network-mode :Channel modes are temporarily unavailable/)
    assert {:noreply, ^cleared} = Hub.handle_info({:mode_request_expired, id}, cleared)
  end

  test "a route loss rejects a pending MODE immediately and makes its timeout inert" do
    {channel, viewer, _replica, _view, _request} = fixture(["o"])
    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, uid} = Projector.uid_for_pid(projector, viewer.pid)
    epoch = UserPayload.new_uid()

    remote_view = %ChannelView{
      origin: @origin,
      channel: ChannelPayload.from_local(channel, @origin),
      remote_present: true
    }

    state =
      routing_state(Replica.new(), %{channel.name_key => remote_view}, epoch)
      |> Map.put(:projector, projector)

    outbound = %Outbound{
      sender_pid: viewer.pid,
      authority: @origin,
      channel: channel.name,
      mode_string: "+n",
      values: []
    }

    assert {:noreply, pending_state} = Hub.handle_info({:mode_request_ready, outbound, uid, 0}, state)
    assert_receive {:link_frame, %{"type" => "mode_request", "id" => id}}

    down = %{"type" => "route_down", "origin" => @origin, "epoch" => epoch}
    assert :ok = Frame.validate(down)
    assert {:reply, :ok, after_drop} = Hub.handle_call({:remote_frame, @origin, self(), down}, self(), pending_state)
    assert after_drop.mode_pending == %{}
    assert_sent_message_contains(viewer.pid, ~r/437 Viewer #network-mode :Channel modes are temporarily unavailable/)
    assert {:noreply, ^after_drop} = Hub.handle_info({:mode_request_expired, id}, after_drop)
  end

  defp fixture(status) do
    {channel, viewer} =
      Memento.transaction!(fn ->
        channel = insert(:channel, name: "#network-mode", modes: [])
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
      remote_members: [
        %RemoteMember{origin: @origin, member: %{"uid" => @uid}, user: remote, effective_modes: status}
      ]
    }

    request = %ModeMutation.Request{
      origin: @origin,
      uid: @uid,
      channel: channel.name,
      mode_string: "+nt",
      values: []
    }

    {channel, viewer, replica, view, request}
  end

  defp routing_state(replica, channel_view, epoch) do
    %Hub.State{
      id: @local_id,
      network: "test-network",
      replays: Hub.ReplayCaches.new(),
      local_epoch: UserPayload.new_uid(),
      local_cursor: 0,
      local_channels: %{},
      replica: replica,
      channel_view: channel_view,
      indexes: %Hub.Indexes{},
      projector: nil,
      links: %{@origin => self()},
      routes: %{@origin => %Route{via: @origin, epoch: epoch, path: [@origin, @local_id]}},
      topic_pending: %{},
      mode_pending: %{},
      kick_pending: %{},
      direct_pending: %{}
    }
  end

  defp request_frame(request, epoch) do
    %{
      "type" => "mode_request",
      "origin" => request.origin,
      "epoch" => epoch,
      "from_uid" => request.uid,
      "to_origin" => @local_id,
      "channel" => request.channel,
      "modes" => request.mode_string,
      "values" => request.values,
      "id" => UserPayload.new_uid(),
      "ttl" => 64
    }
  end
end
