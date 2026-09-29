defmodule ElixIRCd.ServerLink.KickMutationTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.ChannelView.RemoteMember
  alias ElixIRCd.ServerLink.Frame
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.KickMutation.Outbound
  alias ElixIRCd.ServerLink.KickMutation.Pending
  alias ElixIRCd.ServerLink.Projector
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.Route
  alias ElixIRCd.ServerLink.UserPayload

  @local_id "irc.test"
  @remote_id "east.example"
  @remote_uid String.duplicate("a", 32)

  test "target home applies a remote operator KICK once and replays its first decision" do
    {channel, target, replica, view} = target_fixture(["o"])
    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, target_uid} = Projector.uid_for_pid(projector, target.pid)
    epoch = UserPayload.new_uid()
    state = routing_state(replica, %{channel.name_key => view}, epoch) |> Map.put(:projector, projector)
    frame = kick_frame(channel.name, target_uid, epoch)

    assert :ok = Frame.validate(frame)
    assert {:reply, :ok, updated} = Hub.handle_call({:remote_frame, @remote_id, self(), frame}, self(), state)
    assert_receive {:link_frame, %{"type" => "kick_result", "code" => "ok", "id" => id}}
    assert id == frame["id"]
    assert_sent_message_contains(target.pid, ~r/:Remote!.* KICK #network-kick Target :reason\r\n/)

    assert Memento.transaction!(fn -> UserChannels.get_by_user_pid_and_channel_name(target.pid, channel.name) end) ==
             {:error, :user_channel_not_found}

    assert {:reply, :ok, replayed} = Hub.handle_call({:remote_frame, @remote_id, self(), frame}, self(), updated)
    assert_receive {:link_frame, %{"type" => "kick_result", "code" => "ok", "id" => ^id}}
    assert replayed.replays.kick.entries == updated.replays.kick.entries
    assert_sent_messages_amount(target.pid, 1)

    forged = %{frame | "reason" => "changed"}

    assert {:reply, {:error, :reused_message_id}, _} =
             Hub.handle_call({:remote_frame, @remote_id, self(), forged}, self(), replayed)
  end

  test "target home rejects a remote non-operator without deleting membership" do
    {channel, target, replica, view} = target_fixture([])
    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, target_uid} = Projector.uid_for_pid(projector, target.pid)
    epoch = UserPayload.new_uid()
    state = routing_state(replica, %{channel.name_key => view}, epoch) |> Map.put(:projector, projector)

    assert {:reply, :ok, _updated} =
             Hub.handle_call(
               {:remote_frame, @remote_id, self(), kick_frame(channel.name, target_uid, epoch)},
               self(),
               state
             )

    assert_receive {:link_frame, %{"type" => "kick_result", "code" => "operator_required"}}

    assert {:ok, _membership} =
             Memento.transaction!(fn -> UserChannels.get_by_user_pid_and_channel_name(target.pid, channel.name) end)

    assert_sent_messages_amount(target.pid, 0)
  end

  test "local source keeps a typed pending KICK and rejects a mismatched result" do
    {channel, operator, replica, view} = source_fixture()
    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, uid} = Projector.uid_for_pid(projector, operator.pid)
    epoch = UserPayload.new_uid()
    state = routing_state(replica, %{channel.name_key => view}, epoch) |> Map.put(:projector, projector)

    request = %Outbound{
      sender_pid: operator.pid,
      target_origin: @remote_id,
      target_uid: @remote_uid,
      target_nick: "Remote",
      channel: channel.name,
      reason: "reason"
    }

    assert {:noreply, pending_state} = Hub.handle_info({:kick_request_ready, request, uid, 0}, state)
    assert_receive {:link_frame, %{"type" => "kick_request", "id" => id} = sent}
    assert :ok = Frame.validate(sent)
    assert %Pending{uid: ^uid, target_uid: @remote_uid, authority_epoch: ^epoch} = pending_state.kick_pending[id]

    result = %{
      "type" => "kick_result",
      "origin" => @remote_id,
      "epoch" => epoch,
      "to_origin" => @local_id,
      "to_uid" => uid,
      "target_uid" => @remote_uid,
      "channel" => channel.name,
      "id" => id,
      "code" => "operator_required",
      "ttl" => 64
    }

    assert {:reply, {:error, :invalid_kick_result}, ^pending_state} =
             Hub.handle_call(
               {:remote_frame, @remote_id, self(), %{result | "target_uid" => UserPayload.new_uid()}},
               self(),
               pending_state
             )

    assert {:reply, :ok, cleared} = Hub.handle_call({:remote_frame, @remote_id, self(), result}, self(), pending_state)
    assert cleared.kick_pending == %{}
    assert_sent_message_contains(operator.pid, ~r/482 Operator #network-kick :You're not channel operator/)
    assert {:noreply, ^cleared} = Hub.handle_info({:kick_request_expired, id}, cleared)
  end

  test "a pending KICK expires with a single unavailable reply" do
    {channel, operator, replica, view} = source_fixture()
    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, uid} = Projector.uid_for_pid(projector, operator.pid)
    state = routing_state(replica, %{channel.name_key => view}, UserPayload.new_uid()) |> Map.put(:projector, projector)

    request = %Outbound{
      sender_pid: operator.pid,
      target_origin: @remote_id,
      target_uid: @remote_uid,
      target_nick: "Remote",
      channel: channel.name,
      reason: "reason"
    }

    assert {:noreply, pending_state} = Hub.handle_info({:kick_request_ready, request, uid, 0}, state)
    assert_receive {:link_frame, %{"type" => "kick_request", "id" => id}}
    assert {:noreply, cleared} = Hub.handle_info({:kick_request_expired, id}, pending_state)
    assert cleared.kick_pending == %{}

    assert_sent_message_contains(
      operator.pid,
      ~r/437 Operator #network-kick :Channel membership is temporarily unavailable/
    )

    assert {:noreply, ^cleared} = Hub.handle_info({:kick_request_expired, id}, cleared)
  end

  test "route loss clears a pending KICK before its timeout" do
    {channel, operator, replica, view} = source_fixture()
    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, uid} = Projector.uid_for_pid(projector, operator.pid)
    epoch = UserPayload.new_uid()
    state = routing_state(replica, %{channel.name_key => view}, epoch) |> Map.put(:projector, projector)

    request = %Outbound{
      sender_pid: operator.pid,
      target_origin: @remote_id,
      target_uid: @remote_uid,
      target_nick: "Remote",
      channel: channel.name,
      reason: "reason"
    }

    assert {:noreply, pending_state} = Hub.handle_info({:kick_request_ready, request, uid, 0}, state)
    assert_receive {:link_frame, %{"type" => "kick_request", "id" => id}}
    down = %{"type" => "route_down", "origin" => @remote_id, "epoch" => epoch}
    assert {:reply, :ok, dropped} = Hub.handle_call({:remote_frame, @remote_id, self(), down}, self(), pending_state)
    assert dropped.kick_pending == %{}

    assert_sent_message_contains(
      operator.pid,
      ~r/437 Operator #network-kick :Channel membership is temporarily unavailable/
    )

    assert {:noreply, ^dropped} = Hub.handle_info({:kick_request_expired, id}, dropped)
  end

  test "KICK wire frames reject unknown keys, invalid targets and control characters" do
    epoch = UserPayload.new_uid()
    frame = kick_frame("#network-kick", UserPayload.new_uid(), epoch)
    assert :ok = Frame.validate(frame)
    assert {:error, :invalid_frame} = Frame.validate(Map.put(frame, "extra", "ignored"))
    assert {:error, :invalid_frame} = Frame.validate(%{frame | "reason" => "bad\r\nline"})
    assert {:error, :invalid_frame} = Frame.validate(%{frame | "to_uid" => "not-a-uid"})
  end

  defp target_fixture(status) do
    {channel, target} =
      Memento.transaction!(fn ->
        channel = insert(:channel, name: "#network-kick")
        target = insert(:user, nick: "Target")
        insert(:user_channel, user: target, channel: channel)
        {channel, target}
      end)

    remote = build(:user, nick: "Remote") |> UserPayload.from_local(@remote_uid)
    replica = %Replica{users: %{{@remote_id, @remote_uid} => remote}}

    view = %ChannelView{
      origin: @local_id,
      channel: ChannelPayload.from_local(channel, @local_id),
      remote_present: true,
      remote_members: [
        %RemoteMember{origin: @remote_id, member: %{"uid" => @remote_uid}, user: remote, effective_modes: status}
      ]
    }

    {channel, target, replica, view}
  end

  defp source_fixture do
    {channel, operator} =
      Memento.transaction!(fn ->
        channel = insert(:channel, name: "#network-kick")
        operator = insert(:user, nick: "Operator")
        insert(:user_channel, user: operator, channel: channel, modes: [:o])
        {channel, operator}
      end)

    remote = build(:user, nick: "Remote") |> UserPayload.from_local(@remote_uid)
    replica = %Replica{users: %{{@remote_id, @remote_uid} => remote}}

    view = %ChannelView{
      origin: @local_id,
      channel: ChannelPayload.from_local(channel, @local_id),
      remote_present: true,
      remote_members: [
        %RemoteMember{origin: @remote_id, member: %{"uid" => @remote_uid}, user: remote, effective_modes: []}
      ]
    }

    {channel, operator, replica, view}
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
      channel_authorities: %{},
      indexes: %Hub.Indexes{},
      projector: nil,
      links: %{@remote_id => self()},
      routes: %{@remote_id => %Route{via: @remote_id, epoch: epoch, path: [@remote_id, @local_id]}},
      topic_pending: %{},
      mode_pending: %{},
      kick_pending: %{},
      direct_pending: %{}
    }
  end

  defp kick_frame(channel, target_uid, epoch) do
    %{
      "type" => "kick_request",
      "origin" => @remote_id,
      "epoch" => epoch,
      "from_uid" => @remote_uid,
      "to_origin" => @local_id,
      "to_uid" => target_uid,
      "channel" => channel,
      "reason" => "reason",
      "id" => UserPayload.new_uid(),
      "ttl" => 64
    }
  end
end
