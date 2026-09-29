defmodule ElixIRCd.ServerLink.ChannelEventsTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.ServerLink.ChannelEvents
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.ChannelReconciler
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Utils.Protocol

  test "committed remote list deltas announce additions and removals to local channel members" do
    {viewer, channel} =
      Memento.transaction!(fn ->
        viewer = insert(:user, nick: "Viewer")
        channel = insert(:channel, name: "#lists")
        insert(:user_channel, user: viewer, channel: channel)
        {viewer, channel}
      end)

    {base, _member, _identity} = remote_state(channel)
    origin = "east.example"
    list = remote_list(channel, "b", "bad!*@*")
    key = {origin, {channel.name_key, "b", Protocol.mask_key(list["mask"])}}
    added = %{base | lists: %{key => list}}
    staged = %{base | deltas: %{origin => %{entries: [%{"field" => "list", "action" => "upsert", "entry" => list}]}}}

    assert :ok = deliver(staged, added, origin)
    assert_sent_messages([{viewer.pid, ":irc.test MODE #lists +b bad!*@*\r\n"}])

    staged = %{added | deltas: %{origin => %{entries: [%{"field" => "list", "action" => "remove", "entry" => list}]}}}
    assert :ok = deliver(staged, base, origin)
    assert_sent_messages([{viewer.pid, ":irc.test MODE #lists -b bad!*@*\r\n"}])
  end

  test "snapshot list changes announce only masks that become effective" do
    {viewer, channel} =
      Memento.transaction!(fn ->
        viewer = insert(:user, nick: "Viewer")
        channel = insert(:channel, name: "#snapshot-lists")
        insert(:user_channel, user: viewer, channel: channel)
        insert(:channel_ban, channel: channel, mask: "duplicate!*@*")
        {viewer, channel}
      end)

    {base, _member, _identity} = remote_state(channel)
    origin = "east.example"
    duplicate = remote_list(channel, "b", "duplicate!*@*")
    exception = remote_list(channel, "e", "$a:trusted")

    lists =
      Map.new([duplicate, exception], fn list ->
        {{origin, {channel.name_key, list["kind"], Protocol.mask_key(list["mask"])}}, list}
      end)

    added = %{base | lists: lists}
    old_views = ChannelView.select("irc.test", %{}, base)
    new_views = ChannelView.select("irc.test", %{}, added)

    assert :ok = ChannelEvents.deliver_snapshot(base, added, origin, old_views, new_views)
    assert_sent_messages([{viewer.pid, ":irc.test MODE #snapshot-lists +e $a:trusted\r\n"}])

    assert :ok = ChannelEvents.deliver_snapshot(added, base, origin, new_views, old_views)
    assert_sent_messages([{viewer.pid, ":irc.test MODE #snapshot-lists -e $a:trusted\r\n"}])

    assert :ok = ChannelEvents.deliver_route_lists(new_views, old_views)
    assert_sent_messages([{viewer.pid, ":irc.test MODE #snapshot-lists -e $a:trusted\r\n"}])
  end

  test "committed remote membership delta delivers JOIN, status MODE and PART to local users" do
    {viewer, extended, channel} =
      Memento.transaction!(fn ->
        viewer = insert(:user, nick: "Viewer")
        extended = insert(:user, nick: "Extended", capabilities: ["extended-join"])
        channel = insert(:channel, name: "#shared")
        insert(:user_channel, user: viewer, channel: channel)
        insert(:user_channel, user: extended, channel: channel)
        {viewer, extended, channel}
      end)

    {base, member, identity} = remote_state(channel)
    origin = "east.example"
    added = %{base | members: %{identity => member}}

    joined = stage_delta(base, origin, "upsert", member)
    assert :ok = deliver(joined, added, origin)

    assert_sent_messages([
      {viewer.pid, ":Remote!~remote@east.example JOIN #shared\r\n"},
      {extended.pid, ":Remote!~remote@east.example JOIN #shared * :Remote user\r\n"},
      {viewer.pid, ":irc.test MODE #shared +o Remote\r\n"},
      {extended.pid, ":irc.test MODE #shared +o Remote\r\n"}
    ])

    voiced = %{member | "modes" => ["v"]}
    changed = %{added | members: %{identity => voiced}}
    assert :ok = deliver(stage_delta(added, origin, "upsert", voiced), changed, origin)

    assert_sent_messages([
      {viewer.pid, ":irc.test MODE #shared -o Remote\r\n"},
      {extended.pid, ":irc.test MODE #shared -o Remote\r\n"},
      {viewer.pid, ":irc.test MODE #shared +v Remote\r\n"},
      {extended.pid, ":irc.test MODE #shared +v Remote\r\n"}
    ])

    gone = %{changed | members: %{}}
    assert :ok = deliver(stage_delta(changed, origin, "remove", voiced), gone, origin)

    assert_sent_messages([
      {viewer.pid, ":Remote!~remote@east.example PART #shared\r\n"},
      {extended.pid, ":Remote!~remote@east.example PART #shared\r\n"}
    ])
  end

  test "a committed KICK removal announces KICK to local members without a PART" do
    {viewer, channel} =
      Memento.transaction!(fn ->
        viewer = insert(:user, nick: "Viewer")
        channel = insert(:channel, name: "#kick")
        insert(:user_channel, user: viewer, channel: channel)
        {viewer, channel}
      end)

    {base, member, identity} = remote_state(channel)
    old = %{base | members: %{identity => member}}
    current = %{old | members: %{}}

    kick = %{
      "actor_origin" => "east.example",
      "actor_uid" => String.duplicate("b", 32),
      "actor_mask" => "Operator!ident@east.example",
      "reason" => "Removed"
    }

    entry = %{"field" => "member", "action" => "remove", "entry" => member, "kick" => kick}
    staged = %{old | deltas: %{"east.example" => %{entries: [entry]}}}

    assert :ok = deliver(staged, current, "east.example")
    assert_sent_messages([{viewer.pid, ":Operator!ident@east.example KICK #kick Remote :Removed\r\n"}])
  end

  test "a replacement membership announces KICK followed by JOIN" do
    {viewer, channel} =
      Memento.transaction!(fn ->
        viewer = insert(:user, nick: "Viewer")
        channel = insert(:channel, name: "#kick-rejoin")
        insert(:user_channel, user: viewer, channel: channel)
        {viewer, channel}
      end)

    {base, member, identity} = remote_state(channel)
    member = Map.put(member, "joined_at", DateTime.utc_now() |> DateTime.to_iso8601())
    old = %{base | members: %{identity => member}}

    new_member = %{
      member
      | "joined_at" => DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.to_iso8601(),
        "modes" => []
    }

    current = %{old | members: %{identity => new_member}}

    kick = %{
      "actor_origin" => "east.example",
      "actor_uid" => String.duplicate("b", 32),
      "actor_mask" => "Operator!ident@east.example",
      "reason" => "Removed"
    }

    entry = %{"field" => "member", "action" => "remove", "entry" => member, "kick" => kick}

    staged = %{
      old
      | deltas: %{
          "east.example" => %{entries: [entry, %{"field" => "member", "action" => "upsert", "entry" => new_member}]}
        }
    }

    assert :ok = deliver(staged, current, "east.example")

    assert_sent_messages([
      {viewer.pid, ":Operator!ident@east.example KICK #kick-rejoin Remote :Removed\r\n"},
      {viewer.pid, ":Remote!~remote@east.example JOIN #kick-rejoin\r\n"}
    ])
  end

  test "auditorium hides an unprivileged remote JOIN from unprivileged local members" do
    {operator, viewer, channel} =
      Memento.transaction!(fn ->
        operator = insert(:user, nick: "Operator")
        viewer = insert(:user, nick: "Viewer")
        channel = insert(:channel, name: "#auditorium", modes: [:u])
        insert(:user_channel, user: operator, channel: channel, modes: [:o])
        insert(:user_channel, user: viewer, channel: channel)
        {operator, viewer, channel}
      end)

    {base, member, identity} = remote_state(channel)
    member = %{member | "modes" => []}
    added = %{base | members: %{identity => member}}
    assert :ok = deliver(stage_delta(base, "east.example", "upsert", member), added, "east.example")

    assert_sent_messages([{operator.pid, ":Remote!~remote@east.example JOIN #auditorium\r\n"}])
    assert_sent_messages_amount(viewer.pid, 0)
  end

  test "channel timestamp change removes a remote status whose contribution lost authority" do
    {viewer, channel} =
      Memento.transaction!(fn ->
        viewer = insert(:user, nick: "Viewer")
        channel = insert(:channel, name: "#time")
        insert(:user_channel, user: viewer, channel: channel)
        {viewer, channel}
      end)

    {base, member, identity} = remote_state(channel)
    old = %{base | members: %{identity => member}}
    local_channels = %{channel.name_key => ChannelPayload.from_local(channel, "east.example")}
    later_channel = build(:channel, name: channel.name, created_at: DateTime.add(channel.created_at, 1))
    later_payload = ChannelPayload.from_local(later_channel, "east.example")
    updated = %{old | channels: %{{"east.example", channel.name_key} => later_payload}}

    prior = %{
      old
      | deltas: %{
          "east.example" => %{
            entries: [%{"field" => "channel", "action" => "upsert", "entry" => later_payload}]
          }
        }
    }

    assert :ok = deliver(prior, updated, "east.example", local_channels)
    assert_sent_messages([{viewer.pid, ":irc.test MODE #time -o Remote\r\n"}])
  end

  test "a channel authority switch updates status for members from both origins" do
    {viewer, channel} =
      Memento.transaction!(fn ->
        viewer = insert(:user, nick: "Viewer")
        channel = insert(:channel, name: "#authority")
        insert(:user_channel, user: viewer, channel: channel)
        {viewer, channel}
      end)

    {base, east_member, east_identity} = remote_state(channel)
    west_uid = String.duplicate("b", 32)
    west_user = build(:user, nick: "WestUser", ident: "~west", hostname: "west.example")
    west_payload = UserPayload.from_local(west_user, west_uid)
    west_channel = build(:channel, name: channel.name, created_at: DateTime.add(channel.created_at, 1))
    west_metadata = ChannelPayload.from_local(west_channel, "west.example")
    west_member = %{east_member | "uid" => west_uid}
    west_identity = {"west.example", {channel.name_key, west_uid}}

    old = %{
      base
      | users: Map.put(base.users, {"west.example", west_uid}, west_payload),
        channels: Map.put(base.channels, {"west.example", channel.name_key}, west_metadata),
        members: %{east_identity => east_member, west_identity => west_member}
    }

    later_channel = build(:channel, name: channel.name, created_at: DateTime.add(channel.created_at, 2))
    later_metadata = ChannelPayload.from_local(later_channel, "east.example")
    updated = %{old | channels: Map.put(old.channels, {"east.example", channel.name_key}, later_metadata)}

    entry = %{"field" => "channel", "action" => "upsert", "entry" => later_metadata}
    staged = %{old | deltas: %{"east.example" => %{entries: [entry]}}}

    assert :ok = deliver(staged, updated, "east.example")

    assert_sent_messages([
      {viewer.pid, ":irc.test MODE #authority -o Remote\r\n"},
      {viewer.pid, ":irc.test MODE #authority +o WestUser\r\n"}
    ])
  end

  test "auditorium status changes reveal and hide a remote member in the right order" do
    {operator, viewer, channel} =
      Memento.transaction!(fn ->
        operator = insert(:user, nick: "Operator")
        viewer = insert(:user, nick: "Viewer")
        channel = insert(:channel, name: "#status", modes: [:u])
        insert(:user_channel, user: operator, channel: channel, modes: [:o])
        insert(:user_channel, user: viewer, channel: channel)
        {operator, viewer, channel}
      end)

    {base, member, identity} = remote_state(channel)
    plain = %{member | "modes" => []}
    old = %{base | members: %{identity => plain}}
    promoted = %{old | members: %{identity => member}}

    assert :ok = deliver(stage_delta(old, "east.example", "upsert", member), promoted, "east.example")

    assert_sent_messages([
      {operator.pid, ":irc.test MODE #status +o Remote\r\n"},
      {viewer.pid, ":Remote!~remote@east.example JOIN #status\r\n"},
      {viewer.pid, ":irc.test MODE #status +o Remote\r\n"}
    ])

    assert :ok = deliver(stage_delta(promoted, "east.example", "upsert", plain), old, "east.example")

    assert_sent_messages([
      {operator.pid, ":irc.test MODE #status -o Remote\r\n"},
      {viewer.pid, ":irc.test MODE #status -o Remote\r\n"},
      {viewer.pid, ":Remote!~remote@east.example PART #status\r\n"}
    ])
  end

  test "remote auditorium mode changes hide and reveal an existing member" do
    {operator, viewer, channel} =
      Memento.transaction!(fn ->
        operator = insert(:user, nick: "Operator")
        viewer = insert(:user, nick: "Viewer")
        channel = insert(:channel, name: "#toggle")
        insert(:user_channel, user: operator, channel: channel, modes: [:o])
        insert(:user_channel, user: viewer, channel: channel)
        {operator, viewer, channel}
      end)

    {base, member, identity} = remote_state(channel)
    plain = %{member | "modes" => []}
    open = %{base | members: %{identity => plain}}
    remote_channel = Map.fetch!(open.channels, {"east.example", channel.name_key})
    auditorium_channel = %{remote_channel | "modes" => [%{"name" => "u", "parameter" => nil}]}
    hidden = %{open | channels: %{{"east.example", channel.name_key} => auditorium_channel}}
    entry = %{"field" => "channel", "action" => "upsert", "entry" => auditorium_channel}
    staged = %{open | deltas: %{"east.example" => %{entries: [entry]}}}

    assert :ok = deliver(staged, hidden, "east.example")
    assert_sent_messages([{viewer.pid, ":Remote!~remote@east.example PART #toggle\r\n"}])
    assert_sent_messages_amount(operator.pid, 0)

    entry = %{"field" => "channel", "action" => "upsert", "entry" => remote_channel}
    staged = %{hidden | deltas: %{"east.example" => %{entries: [entry]}}}

    assert :ok = deliver(staged, open, "east.example")
    assert_sent_messages([{viewer.pid, ":Remote!~remote@east.example JOIN #toggle\r\n"}])
    assert_sent_messages_amount(operator.pid, 0)
  end

  test "a completed snapshot announces new members and parts retained users who left" do
    {viewer, channel} =
      Memento.transaction!(fn ->
        viewer = insert(:user, nick: "Viewer")
        channel = insert(:channel, name: "#snapshot")
        insert(:user_channel, user: viewer, channel: channel)
        {viewer, channel}
      end)

    {base, member, identity} = remote_state(channel)
    joined = %{base | members: %{identity => member}}
    old_views = ChannelView.select("irc.test", %{}, base)
    new_views = ChannelView.select("irc.test", %{}, joined)

    assert :ok = ChannelEvents.deliver_snapshot(base, joined, "east.example", old_views, new_views)

    assert_sent_messages([
      {viewer.pid, ":Remote!~remote@east.example JOIN #snapshot\r\n"},
      {viewer.pid, ":irc.test MODE #snapshot +o Remote\r\n"}
    ])

    assert :ok = ChannelEvents.deliver_snapshot(joined, base, "east.example", new_views, old_views)
    assert_sent_messages([{viewer.pid, ":Remote!~remote@east.example PART #snapshot\r\n"}])

    departed = %{joined | users: %{}, members: %{}}
    departed_views = ChannelView.select("irc.test", %{}, departed)
    assert :ok = ChannelEvents.deliver_snapshot(joined, departed, "east.example", new_views, departed_views)
    assert_sent_messages_amount(viewer.pid, 0)
  end

  test "a local auditorium mode change reconciles visibility of remote members" do
    {operator, viewer, channel} =
      Memento.transaction!(fn ->
        operator = insert(:user, nick: "Operator")
        viewer = insert(:user, nick: "Viewer")
        channel = insert(:channel, name: "#localmode")
        insert(:user_channel, user: operator, channel: channel, modes: [:o])
        insert(:user_channel, user: viewer, channel: channel)
        {operator, viewer, channel}
      end)

    {base, member, identity} = remote_state(channel)
    later_remote = build(:channel, name: channel.name, created_at: DateTime.add(channel.created_at, 1))
    remote_channel = ChannelPayload.from_local(later_remote, "east.example")

    replica = %{
      base
      | members: %{identity => %{member | "modes" => []}},
        channels: %{{"east.example", channel.name_key} => remote_channel}
    }

    open_channel = ChannelPayload.from_local(channel, "irc.test")
    hidden_channel = %{open_channel | "modes" => [%{"name" => "u", "parameter" => nil}]}
    open_local = %{channel.name_key => open_channel}
    hidden_local = %{channel.name_key => hidden_channel}
    open_view = ChannelView.select("irc.test", open_local, replica)
    hidden_view = ChannelView.select("irc.test", hidden_local, replica)
    frame = %{"type" => "delta_entry", "field" => "channel", "entry" => hidden_channel}

    assert :ok =
             ChannelEvents.deliver_local_delta(replica, open_view, hidden_view, [frame])

    assert_sent_messages([{viewer.pid, ":Remote!~remote@east.example PART #localmode\r\n"}])
    assert_sent_messages_amount(operator.pid, 0)

    frame = %{"type" => "delta_entry", "field" => "channel", "entry" => open_channel}

    assert :ok =
             ChannelEvents.deliver_local_delta(replica, hidden_view, open_view, [frame])

    assert_sent_messages([{viewer.pid, ":Remote!~remote@east.example JOIN #localmode\r\n"}])
    assert_sent_messages_amount(operator.pid, 0)
  end

  test "a losing local operator receives PART for a remote member hidden by the winning auditorium" do
    {operator, channel} =
      Memento.transaction!(fn ->
        operator = insert(:user, nick: "FormerOp")
        channel = insert(:channel, name: "#ts-auditorium", modes: [:u], topic: nil)
        insert(:user_channel, user: operator, channel: channel, modes: [:o])
        {operator, channel}
      end)

    origin = "east.example"
    uid = String.duplicate("a", 32)
    remote_user = build(:user, nick: "Remote", ident: "~remote", hostname: origin) |> UserPayload.from_local(uid)

    old_remote =
      build(:channel, name: channel.name, created_at: DateTime.add(channel.created_at, 1), modes: [:u], topic: nil)

    new_remote =
      build(:channel, name: channel.name, created_at: DateTime.add(channel.created_at, -1), modes: [:u], topic: nil)

    member = %{
      "channel" => channel.name,
      "uid" => uid,
      "modes" => [],
      "joined_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    identity = {origin, {channel.name_key, uid}}

    old = %{
      Replica.new()
      | users: %{{origin, uid} => remote_user},
        channels: %{{origin, channel.name_key} => ChannelPayload.from_local(old_remote, origin)},
        members: %{identity => member}
    }

    current = %{old | channels: %{{origin, channel.name_key} => ChannelPayload.from_local(new_remote, origin)}}
    local_channels = %{channel.name_key => ChannelPayload.from_local(channel, "irc.test")}
    old_views = ChannelView.select("irc.test", local_channels, old)
    new_views = ChannelView.select("irc.test", local_channels, current)
    prior_memberships = ChannelReconciler.reconcile(old_views, new_views, "irc.test")

    assert :ok = ChannelEvents.deliver_snapshot(old, current, origin, old_views, new_views, prior_memberships)

    assert_sent_messages([
      {operator.pid, ":irc.test MODE #ts-auditorium -o FormerOp\r\n"},
      {operator.pid, ":Remote!~remote@east.example PART #ts-auditorium\r\n"}
    ])
  end

  defp remote_state(channel) do
    origin = "east.example"
    uid = String.duplicate("a", 32)
    user = build(:user, nick: "Remote", ident: "~remote", hostname: origin, realname: "Remote user")
    payload = UserPayload.from_local(user, uid)
    channel_payload = ChannelPayload.from_local(channel, origin)
    member = %{"channel" => channel.name, "uid" => uid, "modes" => ["o"]}
    identity = {origin, {channel.name_key, uid}}

    base = %{
      Replica.new()
      | users: %{{origin, uid} => payload},
        channels: %{{origin, channel.name_key} => channel_payload}
    }

    {base, member, identity}
  end

  defp stage_delta(replica, origin, action, member) do
    %{replica | deltas: %{origin => %{entries: [%{"field" => "member", "action" => action, "entry" => member}]}}}
  end

  defp remote_list(channel, kind, mask) do
    %{
      "channel" => channel.name,
      "kind" => kind,
      "mask" => mask,
      "setter" => "Remote!~remote@east.example",
      "set_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp deliver(previous, current, origin, local_channels \\ %{}) do
    previous_view = ChannelView.select("irc.test", local_channels, previous)
    current_view = ChannelView.select("irc.test", local_channels, current)
    ChannelEvents.deliver_delta(previous, current, origin, previous_view, current_view)
  end
end
