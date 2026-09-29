defmodule ElixIRCd.ServerLink.InviteMutationTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Invite
  alias ElixIRCd.Commands.Join
  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.ChannelView.RemoteMember
  alias ElixIRCd.ServerLink.Directory
  alias ElixIRCd.ServerLink.Frame
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.InviteMutation
  alias ElixIRCd.ServerLink.InviteMutation.LocalNotice
  alias ElixIRCd.ServerLink.InviteMutation.Outbound
  alias ElixIRCd.ServerLink.InviteMutation.Pending
  alias ElixIRCd.ServerLink.Projector
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.Route
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.RegisteredChannel.Settings

  @local_id "irc.test"
  @remote_id "east.example"
  @remote_uid String.duplicate("a", 32)

  test "recipient home commits a remote operator invitation once and returns current AWAY" do
    {channel, target, replica, view} = target_fixture([:i], ["o"])
    remote = Map.put(replica.users[{@remote_id, @remote_uid}], "account", "remoteaccount")
    replica = %{replica | users: Map.put(replica.users, {@remote_id, @remote_uid}, remote)}

    watcher =
      Memento.transaction!(fn ->
        watcher = insert(:user, nick: "Watcher", capabilities: ["invite-notify"])
        insert(:user_channel, user: watcher, channel: channel)
        watcher
      end)

    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, target_uid} = Projector.uid_for_pid(projector, target.pid)
    epoch = UserPayload.new_uid()
    state = routing_state(replica, %{channel.name_key => view}, epoch) |> Map.put(:projector, projector)
    frame = request_frame(channel.name, target_uid, epoch)

    assert :ok = Frame.validate(frame)
    assert {:reply, :ok, updated} = Hub.handle_call({:remote_frame, @remote_id, self(), frame}, self(), state)
    assert_receive {:link_frame, %{"type" => "invite_result", "code" => "ok", "away" => "Away", "id" => id}}
    assert id == frame["id"]

    assert {:ok, invite} =
             Memento.transaction!(fn -> ChannelInvites.get_by_user_pid_and_channel_name(target.pid, channel.name) end)

    assert invite.bypass_ban
    assert String.starts_with?(invite.setter, "Remote!")
    assert_sent_message_contains(target.pid, ~r/@account=remoteaccount :Remote!.* INVITE Target #network-invite\r\n/)
    assert_sent_message_contains(watcher.pid, ~r/:Remote!.* INVITE Target #network-invite\r\n/)

    assert {:reply, :ok, replayed} = Hub.handle_call({:remote_frame, @remote_id, self(), frame}, self(), updated)
    assert_receive {:link_frame, %{"type" => "invite_result", "code" => "ok", "id" => ^id}}
    assert replayed.replays.invite.entries == updated.replays.invite.entries
    assert_sent_messages_amount(target.pid, 1)

    forged = %{frame | "to_uid" => UserPayload.new_uid()}

    assert {:reply, {:error, :reused_message_id}, _} =
             Hub.handle_call({:remote_frame, @remote_id, self(), forged}, self(), replayed)
  end

  test "recipient home rejects non-operator on an invite-only channel without persisting" do
    {channel, target, replica, view} = target_fixture([:i], [])
    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, target_uid} = Projector.uid_for_pid(projector, target.pid)
    epoch = UserPayload.new_uid()
    state = routing_state(replica, %{channel.name_key => view}, epoch) |> Map.put(:projector, projector)

    assert {:reply, :ok, _updated} =
             Hub.handle_call(
               {:remote_frame, @remote_id, self(), request_frame(channel.name, target_uid, epoch)},
               self(),
               state
             )

    assert_receive {:link_frame, %{"type" => "invite_result", "code" => "operator_required", "away" => nil}}

    assert {:error, :channel_invite_not_found} =
             Memento.transaction!(fn -> ChannelInvites.get_by_user_pid_and_channel_name(target.pid, channel.name) end)

    assert_sent_messages_amount(target.pid, 0)
  end

  test "recipient home rejects a mismatched channel contribution" do
    {channel, target, replica, view} = target_fixture([], [])
    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, target_uid} = Projector.uid_for_pid(projector, target.pid)
    epoch = UserPayload.new_uid()
    mismatched = %{view | remote_members: Enum.map(view.remote_members, &%{&1 | effective: false})}
    state = routing_state(replica, %{channel.name_key => mismatched}, epoch) |> Map.put(:projector, projector)

    assert {:reply, :ok, _updated} =
             Hub.handle_call(
               {:remote_frame, @remote_id, self(), request_frame(channel.name, target_uid, epoch)},
               self(),
               state
             )

    assert_receive {:link_frame, %{"type" => "invite_result", "code" => "not_on_channel"}}
    assert_sent_messages_amount(target.pid, 0)
  end

  test "recipient home rejects a registered channel until services authority is shared" do
    {channel, target, replica, view} = target_fixture([:i], ["o"])

    Memento.transaction!(fn ->
      insert(:registered_channel, name: channel.name, founder: "founder", settings: Settings.new(%{}))
    end)

    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, target_uid} = Projector.uid_for_pid(projector, target.pid)
    epoch = UserPayload.new_uid()
    state = routing_state(replica, %{channel.name_key => view}, epoch) |> Map.put(:projector, projector)

    assert {:reply, :ok, _updated} =
             Hub.handle_call(
               {:remote_frame, @remote_id, self(), request_frame(channel.name, target_uid, epoch)},
               self(),
               state
             )

    assert_receive {:link_frame, %{"type" => "invite_result", "code" => "registered_channel"}}

    assert {:error, :channel_invite_not_found} =
             Memento.transaction!(fn -> ChannelInvites.get_by_user_pid_and_channel_name(target.pid, channel.name) end)
  end

  test "local inviter gets 341 and AWAY only after an authenticated recipient-home result" do
    {channel, inviter, replica, view} = source_fixture()
    table = ChannelDirectory.create()
    ChannelDirectory.sync(table, %{}, %{channel.name_key => view})

    watcher =
      Memento.transaction!(fn ->
        watcher = insert(:user, nick: "Watcher", capabilities: ["invite-notify"])
        insert(:user_channel, user: watcher, channel: channel)
        watcher
      end)

    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, uid} = Projector.uid_for_pid(projector, inviter.pid)
    epoch = UserPayload.new_uid()
    state = routing_state(replica, %{channel.name_key => view}, epoch) |> Map.put(:projector, projector)

    outbound = %Outbound{
      sender_pid: inviter.pid,
      target_origin: @remote_id,
      target_uid: @remote_uid,
      target_nick: "Remote",
      channel: channel.name
    }

    assert {:noreply, pending_state} = Hub.handle_info({:invite_request_ready, outbound, uid, 0}, state)
    assert_receive {:link_frame, %{"type" => "invite_request", "id" => id} = sent}
    assert :ok = Frame.validate(sent)
    assert %Pending{uid: ^uid, target_uid: @remote_uid, authority_epoch: ^epoch} = pending_state.invite_pending[id]
    assert_sent_messages_amount(inviter.pid, 0)

    result = %{
      "type" => "invite_result",
      "origin" => @remote_id,
      "epoch" => epoch,
      "to_origin" => @local_id,
      "to_uid" => uid,
      "target_uid" => @remote_uid,
      "channel" => channel.name,
      "id" => id,
      "code" => "ok",
      "away" => "Gone",
      "ttl" => 64
    }

    assert {:reply, {:error, :invalid_invite_result}, ^pending_state} =
             Hub.handle_call(
               {:remote_frame, @remote_id, self(), %{result | "target_uid" => UserPayload.new_uid()}},
               self(),
               pending_state
             )

    assert {:reply, :ok, cleared} = Hub.handle_call({:remote_frame, @remote_id, self(), result}, self(), pending_state)
    assert cleared.invite_pending == %{}
    assert_receive {:link_frame, %{"type" => "invite_notice", "id" => ^id, "target_uid" => @remote_uid} = notice}
    assert :ok = Frame.validate(notice)
    assert notice["channel_creator"] == view.channel["creator"]
    assert notice["channel_created_at"] == view.channel["created_at"]
    assert_sent_message_contains(watcher.pid, ~r/:Inviter!.* INVITE Remote #network-invite\r\n/)

    assert_sent_messages([
      {inviter.pid, ":irc.test 301 Inviter Remote :Gone\r\n"},
      {inviter.pid, ":irc.test 341 Inviter Remote #network-invite\r\n"}
    ])

    assert {:noreply, ^cleared} = Hub.handle_info({:invite_request_expired, id}, cleared)
    assert {:reply, :ok, ^cleared} = Hub.handle_call({:remote_frame, @remote_id, self(), result}, self(), cleared)
    refute_receive {:link_frame, %{"type" => "invite_notice"}}
  end

  test "a third home relays one accepted notice and notifies only members of the selected channel" do
    {channel, _target, replica, view} = target_fixture([], [])

    {watcher, plain_watcher} =
      Memento.transaction!(fn ->
        watcher = insert(:user, nick: "Watcher", capabilities: ["invite-notify", "account-tag"])
        plain_watcher = insert(:user, nick: "Plain", capabilities: ["invite-notify"])
        insert(:user_channel, user: watcher, channel: channel)
        insert(:user_channel, user: plain_watcher, channel: channel)
        {watcher, plain_watcher}
      end)

    table = ChannelDirectory.create()
    ChannelDirectory.sync(table, %{}, %{channel.name_key => view})
    epoch = UserPayload.new_uid()
    state = routing_state(replica, %{channel.name_key => view}, epoch)
    state = %{state | id: "middle.example", links: %{@remote_id => self(), "west.example" => self()}}

    notice = %InviteMutation.Notice{
      origin: @remote_id,
      epoch: epoch,
      id: UserPayload.new_uid(),
      uid: @remote_uid,
      sender_mask: "Remote!ident@host.example",
      sender_account: "remoteaccount",
      target_origin: "west.example",
      target_uid: UserPayload.new_uid(),
      target_nick: "Target",
      channel: channel.name,
      channel_ref: %InviteMutation.ChannelRef{
        creator: view.channel["creator"],
        created_at: view.channel["created_at"]
      },
      ttl: 2
    }

    frame = InviteMutation.notice_frame(notice)
    assert :ok = Frame.validate(frame)

    assert {:reply, {:error, :unknown_route}, ^state} =
             Hub.handle_call({:remote_frame, "west.example", self(), frame}, self(), state)

    assert {:reply, {:error, :unknown_route}, ^state} =
             Hub.handle_call(
               {:remote_frame, @remote_id, self(), %{frame | "epoch" => UserPayload.new_uid()}},
               self(),
               state
             )

    assert {:reply, :ok, updated} = Hub.handle_call({:remote_frame, @remote_id, self(), frame}, self(), state)

    assert_sent_message_contains(
      watcher.pid,
      ~r/@account=remoteaccount :Remote!ident@host.example INVITE Target #network-invite\r\n/
    )

    assert_sent_message_contains(plain_watcher.pid, ~r/^:Remote!ident@host.example INVITE Target #network-invite\r\n/)
    assert_sent_messages_amount(watcher.pid, 1)
    assert_sent_messages_amount(plain_watcher.pid, 1)
    assert_receive {:link_frame, %{"type" => "invite_notice", "ttl" => 1, "id" => id}}
    assert id == notice.id

    assert {:reply, :ok, replayed} = Hub.handle_call({:remote_frame, @remote_id, self(), frame}, self(), updated)
    assert_sent_messages_amount(watcher.pid, 0)
    assert_sent_messages_amount(plain_watcher.pid, 0)
    refute_receive {:link_frame, %{"type" => "invite_notice"}}

    another = %{
      frame
      | "id" => UserPayload.new_uid(),
        "channel_created_at" => DateTime.add(channel.created_at, 1) |> DateTime.to_iso8601()
    }

    assert {:reply, :ok, _} = Hub.handle_call({:remote_frame, @remote_id, self(), another}, self(), replayed)
    assert_sent_messages_amount(watcher.pid, 0)
    assert_sent_messages_amount(plain_watcher.pid, 0)
    assert_receive {:link_frame, %{"type" => "invite_notice", "id" => another_id}}
    assert another_id == another["id"]

    terminal = %{frame | "id" => UserPayload.new_uid(), "ttl" => 1}
    assert {:reply, :ok, _} = Hub.handle_call({:remote_frame, @remote_id, self(), terminal}, self(), replayed)
    assert_sent_messages_amount(watcher.pid, 1)
    assert_sent_messages_amount(plain_watcher.pid, 1)
    refute_receive {:link_frame, %{"type" => "invite_notice"}}

    recipient_home = %{state | id: "west.example"}
    assert {:reply, :ok, _} = Hub.handle_call({:remote_frame, @remote_id, self(), frame}, self(), recipient_home)
    assert_sent_messages_amount(watcher.pid, 0)
    assert_sent_messages_amount(plain_watcher.pid, 0)
  end

  test "pending INVITE expires and a route loss rejects another request once" do
    {channel, inviter, replica, view} = source_fixture()
    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, uid} = Projector.uid_for_pid(projector, inviter.pid)
    epoch = UserPayload.new_uid()
    state = routing_state(replica, %{channel.name_key => view}, epoch) |> Map.put(:projector, projector)

    outbound = %Outbound{
      sender_pid: inviter.pid,
      target_origin: @remote_id,
      target_uid: @remote_uid,
      target_nick: "Remote",
      channel: channel.name
    }

    assert {:noreply, pending_state} = Hub.handle_info({:invite_request_ready, outbound, uid, 0}, state)
    assert_receive {:link_frame, %{"type" => "invite_request", "id" => id}}
    assert {:noreply, expired} = Hub.handle_info({:invite_request_expired, id}, pending_state)
    assert expired.invite_pending == %{}

    assert_sent_message_contains(
      inviter.pid,
      ~r/437 Inviter #network-invite :Channel invitations are temporarily unavailable/
    )

    assert {:noreply, ^expired} = Hub.handle_info({:invite_request_expired, id}, expired)

    assert {:noreply, pending_again} = Hub.handle_info({:invite_request_ready, outbound, uid, 0}, state)
    assert_receive {:link_frame, %{"type" => "invite_request", "id" => next_id}}
    down = %{"type" => "route_down", "origin" => @remote_id, "epoch" => epoch}
    assert {:reply, :ok, dropped} = Hub.handle_call({:remote_frame, @remote_id, self(), down}, self(), pending_again)
    assert dropped.invite_pending == %{}

    assert_sent_message_contains(
      inviter.pid,
      ~r/437 Inviter #network-invite :Channel invitations are temporarily unavailable/
    )

    assert {:noreply, ^dropped} = Hub.handle_info({:invite_request_expired, next_id}, dropped)
  end

  test "a result for an older channel identity does not notify members of its replacement" do
    {channel, inviter, replica, view} = source_fixture()

    watcher =
      Memento.transaction!(fn ->
        watcher = insert(:user, nick: "Watcher", capabilities: ["invite-notify"])
        insert(:user_channel, user: watcher, channel: channel)
        watcher
      end)

    table = ChannelDirectory.create()
    ChannelDirectory.sync(table, %{}, %{channel.name_key => view})
    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, uid} = Projector.uid_for_pid(projector, inviter.pid)
    epoch = UserPayload.new_uid()
    state = routing_state(replica, %{channel.name_key => view}, epoch) |> Map.put(:projector, projector)

    outbound = %Outbound{
      sender_pid: inviter.pid,
      target_origin: @remote_id,
      target_uid: @remote_uid,
      target_nick: "Remote",
      channel: channel.name
    }

    assert {:noreply, pending_state} = Hub.handle_info({:invite_request_ready, outbound, uid, 0}, state)
    assert_receive {:link_frame, %{"type" => "invite_request", "id" => id}}

    replacement = %{
      view
      | channel: Map.put(view.channel, "created_at", DateTime.add(channel.created_at, 1) |> DateTime.to_iso8601())
    }

    ChannelDirectory.sync(table, %{channel.name_key => view}, %{channel.name_key => replacement})

    result = %{
      "type" => "invite_result",
      "origin" => @remote_id,
      "epoch" => epoch,
      "to_origin" => @local_id,
      "to_uid" => uid,
      "target_uid" => @remote_uid,
      "channel" => channel.name,
      "id" => id,
      "code" => "ok",
      "away" => nil,
      "ttl" => 64
    }

    assert {:reply, :ok, _cleared} = Hub.handle_call({:remote_frame, @remote_id, self(), result}, self(), pending_state)
    assert_sent_message_contains(inviter.pid, ~r/341 Inviter Remote #network-invite\r\n/)
    assert_sent_messages_amount(watcher.pid, 0)
  end

  test "remote-only invite is consumed when the local recipient adopts and joins the channel" do
    target = Memento.transaction!(fn -> insert(:user, nick: "Target") end)
    remote_channel = build(:channel, name: "#network-invite", modes: [:i])
    payload = ChannelPayload.from_local(remote_channel, @remote_id)
    remote = build(:user, nick: "Remote") |> UserPayload.from_local(@remote_uid)
    replica = %Replica{users: %{{@remote_id, @remote_uid} => remote}}

    view = %ChannelView{
      origin: @remote_id,
      channel: payload,
      remote_present: true,
      remote_members: [
        %RemoteMember{origin: @remote_id, member: %{"uid" => @remote_uid}, user: remote, effective_modes: ["o"]}
      ]
    }

    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    {:ok, target_uid} = Projector.uid_for_pid(projector, target.pid)

    request = %InviteMutation.Request{
      origin: @remote_id,
      uid: @remote_uid,
      target_uid: target_uid,
      channel: remote_channel.name
    }

    assert {:ok, _accepted} = InviteMutation.apply_remote(request, replica, view, projector)

    assert {:ok, _invite} =
             Memento.transaction!(fn ->
               ChannelInvites.get_by_user_pid_and_channel_name(target.pid, remote_channel.name)
             end)

    prior_links = Application.fetch_env!(:elixircd, :server_links)
    Application.put_env(:elixircd, :server_links, Keyword.put(prior_links, :enabled, true))
    on_exit(fn -> Application.put_env(:elixircd, :server_links, prior_links) end)
    table = ChannelDirectory.create()
    ChannelDirectory.sync(table, %{}, %{remote_channel.name_key => view})

    Memento.transaction!(fn -> Invite.handle(target, %Message{command: "INVITE", params: []}) end)
    assert_sent_message_contains(target.pid, ~r/336 Target #network-invite\r\n/)

    Memento.transaction!(fn -> Join.handle(target, %Message{command: "JOIN", params: [remote_channel.name]}) end)

    assert {:ok, _membership} =
             Memento.transaction!(fn ->
               UserChannels.get_by_user_pid_and_channel_name(target.pid, remote_channel.name)
             end)

    assert {:error, :channel_invite_not_found} =
             Memento.transaction!(fn ->
               ChannelInvites.get_by_user_pid_and_channel_name(target.pid, remote_channel.name)
             end)
  end

  test "a committed invitation between local clients announces to remote channel members" do
    prior_links = Application.fetch_env!(:elixircd, :server_links)
    Application.put_env(:elixircd, :server_links, Keyword.put(prior_links, :enabled, true))
    on_exit(fn -> Application.put_env(:elixircd, :server_links, prior_links) end)

    {channel, inviter, replica, view} = source_fixture()
    target = Memento.transaction!(fn -> insert(:user, nick: "Target") end)
    directory = Directory.create()
    Directory.sync(directory, Replica.new(), replica)
    table = ChannelDirectory.create()
    ChannelDirectory.sync(table, %{}, %{channel.name_key => view})
    projector = start_supervised!({Projector, [name: nil, id: @local_id]})
    state = routing_state(replica, %{channel.name_key => view}, UserPayload.new_uid())
    state = %{state | projector: projector}
    assert Process.whereis(Hub) == nil
    Process.register(self(), Hub)

    Observability.transaction(fn ->
      Invite.handle(inviter, %Message{command: "INVITE", params: [target.nick, channel.name]})
      refute_receive {:"$gen_cast", {:announce_invite, _}}
    end)

    assert_receive {:"$gen_cast", {:announce_invite, %LocalNotice{} = request}}
    assert {:noreply, ^state} = Hub.handle_cast({:announce_invite, request}, state)
    assert_receive {:local_invite_notice_ready, ^request, sender_uid, target_uid}

    assert {:noreply, ^state} =
             Hub.handle_info({:local_invite_notice_ready, request, sender_uid, target_uid}, state)

    assert_receive {:link_frame,
                    %{"type" => "invite_notice", "origin" => @local_id, "target_origin" => @local_id} = frame}

    assert :ok = Frame.validate(frame)
    assert frame["from_uid"] == sender_uid
    assert frame["target_uid"] == target_uid
  end

  test "INVITE command queues the typed remote target after commit without early 341" do
    prior_links = Application.fetch_env!(:elixircd, :server_links)
    Application.put_env(:elixircd, :server_links, Keyword.put(prior_links, :enabled, true))
    on_exit(fn -> Application.put_env(:elixircd, :server_links, prior_links) end)

    {channel, inviter, replica, view} = source_fixture()
    directory = Directory.create()
    Directory.sync(directory, Replica.new(), replica)
    table = ChannelDirectory.create()
    ChannelDirectory.sync(table, %{}, %{channel.name_key => view})
    assert Process.whereis(Hub) == nil
    Process.register(self(), Hub)

    Observability.transaction(fn ->
      Invite.handle(inviter, %Message{command: "INVITE", params: ["Remote", channel.name]})
      refute_receive {:"$gen_cast", _}
      assert_sent_messages_amount(inviter.pid, 0)
    end)

    assert_receive {:"$gen_cast", {:request_invite, %Outbound{target_uid: @remote_uid, channel: "#network-invite"}}}
    assert_sent_messages_amount(inviter.pid, 0)
  end

  test "registered source channel refuses a remote invitation until services authority is shared" do
    prior_links = Application.fetch_env!(:elixircd, :server_links)
    Application.put_env(:elixircd, :server_links, Keyword.put(prior_links, :enabled, true))
    on_exit(fn -> Application.put_env(:elixircd, :server_links, prior_links) end)

    {channel, inviter, replica, view} = source_fixture()
    directory = Directory.create()
    Directory.sync(directory, Replica.new(), replica)
    table = ChannelDirectory.create()
    ChannelDirectory.sync(table, %{}, %{channel.name_key => view})

    Memento.transaction!(fn ->
      insert(:registered_channel, name: channel.name, founder: "founder", settings: Settings.new(%{}))
    end)

    assert Process.whereis(Hub) == nil
    Process.register(self(), Hub)

    Observability.transaction(fn ->
      Invite.handle(inviter, %Message{command: "INVITE", params: ["Remote", channel.name]})
    end)

    assert_sent_message_contains(
      inviter.pid,
      ~r/437 Inviter #network-invite :Channel invitations are temporarily unavailable/
    )

    refute_receive {:"$gen_cast", {:request_invite, _request}}
  end

  test "intermediate server forwards authenticated INVITE request and result within TTL" do
    remote = build(:user, nick: "Remote") |> UserPayload.from_local(@remote_uid)
    replica = %Replica{users: %{{@remote_id, @remote_uid} => remote}}
    east_epoch = UserPayload.new_uid()
    west_epoch = UserPayload.new_uid()
    west = "west.example"
    target_uid = UserPayload.new_uid()

    state =
      routing_state(replica, %{}, east_epoch)
      |> Map.put(:id, "middle.example")
      |> Map.put(:links, %{@remote_id => self(), west => self()})
      |> Map.put(:routes, %{
        @remote_id => %Route{via: @remote_id, epoch: east_epoch, path: [@remote_id, "middle.example"]},
        west => %Route{via: west, epoch: west_epoch, path: [west, "middle.example"]}
      })

    frame = request_frame("#network-invite", target_uid, east_epoch)
    frame = %{frame | "to_origin" => west, "ttl" => 2}
    assert {:reply, :ok, ^state} = Hub.handle_call({:remote_frame, @remote_id, self(), frame}, self(), state)
    assert_receive {:link_frame, %{"type" => "invite_request", "id" => id, "ttl" => 1}}
    assert id == frame["id"]

    result = %{
      "type" => "invite_result",
      "origin" => west,
      "epoch" => west_epoch,
      "to_origin" => @remote_id,
      "to_uid" => @remote_uid,
      "target_uid" => target_uid,
      "channel" => frame["channel"],
      "id" => id,
      "code" => "ok",
      "away" => nil,
      "ttl" => 2
    }

    assert :ok = Frame.validate(result)
    assert {:reply, :ok, ^state} = Hub.handle_call({:remote_frame, west, self(), result}, self(), state)
    assert_receive {:link_frame, %{"type" => "invite_result", "id" => ^id, "ttl" => 1}}
  end

  test "INVITE frames reject unknown keys, wrong UID and a forged away on failure" do
    frame = request_frame("#network-invite", UserPayload.new_uid(), UserPayload.new_uid())
    assert :ok = Frame.validate(frame)
    assert {:error, :invalid_frame} = Frame.validate(Map.put(frame, "extra", "ignored"))
    assert {:error, :invalid_frame} = Frame.validate(%{frame | "to_uid" => "bad"})

    result = %{
      "type" => "invite_result",
      "origin" => @local_id,
      "epoch" => UserPayload.new_uid(),
      "to_origin" => @remote_id,
      "to_uid" => @remote_uid,
      "target_uid" => frame["to_uid"],
      "channel" => frame["channel"],
      "id" => frame["id"],
      "code" => "unknown_target",
      "away" => "forged",
      "ttl" => 64
    }

    assert {:error, :invalid_frame} = Frame.validate(result)

    notice = %InviteMutation.Notice{
      origin: @local_id,
      epoch: UserPayload.new_uid(),
      id: UserPayload.new_uid(),
      uid: @remote_uid,
      sender_mask: "Remote!ident@host.example",
      sender_account: nil,
      target_origin: @remote_id,
      target_uid: frame["to_uid"],
      target_nick: "Target",
      channel: frame["channel"],
      channel_ref: %InviteMutation.ChannelRef{
        creator: @local_id,
        created_at: DateTime.utc_now() |> DateTime.to_iso8601()
      },
      ttl: 64
    }

    notice_frame = InviteMutation.notice_frame(notice)
    assert :ok = Frame.validate(notice_frame)
    assert {:error, :invalid_frame} = Frame.validate(Map.put(notice_frame, "pid", "forged"))
    assert {:error, :invalid_frame} = Frame.validate(%{notice_frame | "from_mask" => "Bad\r\nNOTICE"})
    assert {:error, :invalid_frame} = Frame.validate(%{notice_frame | "from_account" => "Bad\r\nNOTICE"})
    assert {:error, :invalid_frame} = Frame.validate(%{notice_frame | "channel_created_at" => "yesterday"})
  end

  defp target_fixture(modes, status) do
    {channel, target} =
      Memento.transaction!(fn ->
        channel = insert(:channel, name: "#network-invite", modes: modes)
        target = insert(:user, nick: "Target", away_message: "Away", capabilities: ["account-tag"])
        {channel, target}
      end)

    remote = build(:user, nick: "Remote") |> UserPayload.from_local(@remote_uid)
    replica = %Replica{users: %{{@remote_id, @remote_uid} => remote}}

    view = %ChannelView{
      origin: @local_id,
      channel: ChannelPayload.from_local(channel),
      remote_present: true,
      remote_members: [
        %RemoteMember{origin: @remote_id, member: %{"uid" => @remote_uid}, user: remote, effective_modes: status}
      ]
    }

    {channel, target, replica, view}
  end

  defp source_fixture do
    {channel, inviter} =
      Memento.transaction!(fn ->
        channel = insert(:channel, name: "#network-invite", modes: [:i])
        inviter = insert(:user, nick: "Inviter")
        insert(:user_channel, user: inviter, channel: channel, modes: [:o])
        {channel, inviter}
      end)

    remote = build(:user, nick: "Remote") |> UserPayload.from_local(@remote_uid)

    replica = %Replica{
      users: %{{@remote_id, @remote_uid} => remote},
      nick_keys: %{"remote" => {@remote_id, @remote_uid}}
    }

    view = %ChannelView{origin: @local_id, channel: ChannelPayload.from_local(channel), remote_present: true}
    {channel, inviter, replica, view}
  end

  defp routing_state(replica, channel_view, epoch) do
    %Hub.State{
      id: @local_id,
      network: "test-network",
      local_epoch: UserPayload.new_uid(),
      replica: replica,
      channel_view: channel_view,
      indexes: %Hub.Indexes{},
      replays: Hub.ReplayCaches.new(),
      links: %{@remote_id => self()},
      routes: %{@remote_id => %Route{via: @remote_id, epoch: epoch, path: [@remote_id, @local_id]}}
    }
  end

  defp request_frame(channel, target_uid, epoch) do
    %{
      "type" => "invite_request",
      "origin" => @remote_id,
      "epoch" => epoch,
      "from_uid" => @remote_uid,
      "to_origin" => @local_id,
      "to_uid" => target_uid,
      "channel" => channel,
      "id" => UserPayload.new_uid(),
      "ttl" => 64
    }
  end
end
