defmodule ElixIRCd.ServerLink.UserEventsTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.UserAcceptRemotes
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.UserEvents
  alias ElixIRCd.ServerLink.UserPayload

  @origin "east.example"
  @uid String.duplicate("a", 32)

  test "remote UID departure revokes local ACCEPT permissions on QUIT and route loss" do
    local = Memento.transaction!(fn -> insert(:user, nick: "Local") end)
    old = remote_state([])
    removed = %{old | users: %{}, members: %{}}
    identity = {@origin, @uid}

    Memento.transaction!(fn -> UserAcceptRemotes.create(local.pid, identity) end)
    frame = %{"type" => "user_remove", "origin" => @origin, "uid" => @uid}
    assert :ok = UserEvents.deliver(frame, old, removed, %{})
    assert nil == Memento.transaction!(fn -> UserAcceptRemotes.get_by_user_pid_and_identity(local.pid, identity) end)

    Memento.transaction!(fn -> UserAcceptRemotes.create(local.pid, identity) end)
    assert :ok = UserEvents.deliver_departures(old, removed, %{}, "Server link lost")
    assert nil == Memento.transaction!(fn -> UserAcceptRemotes.get_by_user_pid_and_identity(local.pid, identity) end)
  end

  test "remote NICK and QUIT reach each visible local client once across shared channels" do
    {viewer, first, second} =
      Memento.transaction!(fn ->
        viewer = insert(:user, nick: "Viewer")
        first = insert(:channel, name: "#one")
        second = insert(:channel, name: "#two")
        insert(:user_channel, user: viewer, channel: first)
        insert(:user_channel, user: viewer, channel: second)
        {viewer, first, second}
      end)

    old = remote_state([first, second])
    new_user = old.users[{@origin, @uid}] |> Map.put("nick", "Renamed")
    changed = %{old | users: %{{@origin, @uid} => new_user}}
    views = ChannelView.select("irc.test", %{}, old)
    nick_frame = %{"type" => "user_upsert", "origin" => @origin, "user" => new_user}

    assert :ok = UserEvents.deliver(nick_frame, old, changed, views)
    assert_sent_messages([{viewer.pid, ":Remote!~remote@east.example NICK Renamed\r\n"}])

    new_views = ChannelView.select("irc.test", %{}, changed)
    removed = %{changed | users: %{}, members: %{}}
    quit_frame = %{"type" => "user_remove", "origin" => @origin, "uid" => @uid}

    assert :ok = UserEvents.deliver(quit_frame, changed, removed, new_views)
    assert_sent_messages([{viewer.pid, ":Renamed!~remote@east.example QUIT :Client Quit\r\n"}])
  end

  test "remote profile refresh and first appearance do not send a nickname event" do
    {viewer, channel} = local_channel("#profile")
    old = remote_state([channel])
    user = old.users[{@origin, @uid}]
    refreshed = %{user | "away" => "gone"}
    changed = %{old | users: %{{@origin, @uid} => refreshed}}
    views = ChannelView.select("irc.test", %{}, old)
    frame = %{"type" => "user_upsert", "origin" => @origin, "user" => refreshed}

    assert :ok = UserEvents.deliver(frame, old, changed, views)
    assert :ok = UserEvents.deliver(frame, %{old | users: %{}}, changed, views)
    assert_sent_messages_amount(viewer.pid, 0)
  end

  test "committed remote AWAY updates reach capable shared and extended MONITOR watchers once" do
    {shared, monitored, plain, first, second} =
      Memento.transaction!(fn ->
        shared = insert(:user, nick: "Shared", capabilities: ["away-notify", "extended-monitor"])
        monitored = insert(:user, nick: "Monitored", capabilities: ["away-notify", "extended-monitor"])
        plain = insert(:user, nick: "Plain")
        first = insert(:channel, name: "#away-one")
        second = insert(:channel, name: "#away-two")
        insert(:user_channel, user: shared, channel: first)
        insert(:user_channel, user: shared, channel: second)
        insert(:user_channel, user: plain, channel: first)
        insert(:user_monitor, user: shared, target_nick: "Remote")
        insert(:user_monitor, user: monitored, target_nick: "Remote")
        {shared, monitored, plain, first, second}
      end)

    old = remote_state([first, second])
    user = old.users[{@origin, @uid}]
    away = %{user | "away" => "Stepped out"}
    current = %{old | users: %{{@origin, @uid} => away}}
    views = ChannelView.select("irc.test", %{}, old)
    frame = %{"type" => "user_upsert", "origin" => @origin, "user" => away}

    assert :ok = UserEvents.deliver(frame, old, current, views)

    assert_sent_messages([
      {shared.pid, ":Remote!~remote@east.example AWAY :Stepped out\r\n"},
      {monitored.pid, ":Remote!~remote@east.example AWAY :Stepped out\r\n"}
    ])

    assert_sent_messages_amount(plain.pid, 0)

    clear = %{user | "away" => nil}
    cleared = %{old | users: %{{@origin, @uid} => clear}}
    snapshot = %{"type" => "snapshot_end", "origin" => @origin}
    assert :ok = UserEvents.deliver(snapshot, current, cleared, views)

    assert_sent_messages([
      {shared.pid, ":Remote!~remote@east.example AWAY\r\n"},
      {monitored.pid, ":Remote!~remote@east.example AWAY\r\n"}
    ])
  end

  test "remote user arrival, nickname change and departure update local MONITOR subscribers" do
    watcher =
      Memento.transaction!(fn ->
        watcher = insert(:user, nick: "Watcher")
        insert(:user_monitor, user: watcher, target_nick: "Remote")
        insert(:user_monitor, user: watcher, target_nick: "Renamed")
        watcher
      end)

    current = remote_state([])
    user = current.users[{@origin, @uid}]
    frame = %{"type" => "user_upsert", "origin" => @origin, "user" => user}
    assert :ok = UserEvents.deliver(frame, Replica.new(), current, %{})
    assert_sent_messages([{watcher.pid, ":irc.test 730 Watcher :Remote!~remote@east.example\r\n"}])

    renamed = %{user | "nick" => "Renamed"}
    changed = %{current | users: %{{@origin, @uid} => renamed}}
    assert :ok = UserEvents.deliver(%{frame | "user" => renamed}, current, changed, %{})

    assert_sent_messages([
      {watcher.pid, ":irc.test 731 Watcher :Remote\r\n"},
      {watcher.pid, ":irc.test 730 Watcher :Renamed!~remote@east.example\r\n"}
    ])

    removed = %{changed | users: %{}}

    assert :ok =
             UserEvents.deliver(%{"type" => "user_remove", "origin" => @origin, "uid" => @uid}, changed, removed, %{})

    assert_sent_messages([{watcher.pid, ":irc.test 731 Watcher :Renamed\r\n"}])

    snapshot = %{"type" => "snapshot_end", "origin" => @origin}
    assert :ok = UserEvents.deliver(snapshot, Replica.new(), current, %{})
    assert_sent_messages([{watcher.pid, ":irc.test 730 Watcher :Remote!~remote@east.example\r\n"}])
  end

  test "auditorium limits remote NICK and QUIT to privileged local members" do
    {operator, viewer, channel} =
      Memento.transaction!(fn ->
        operator = insert(:user, nick: "Operator")
        viewer = insert(:user, nick: "Viewer")
        channel = insert(:channel, name: "#private", modes: [:u])
        insert(:user_channel, user: operator, channel: channel, modes: [:o])
        insert(:user_channel, user: viewer, channel: channel)
        {operator, viewer, channel}
      end)

    old = remote_state([channel], [])
    user = old.users[{@origin, @uid}]
    new_user = %{user | "nick" => "Renamed"}
    changed = %{old | users: %{{@origin, @uid} => new_user}}
    views = ChannelView.select("irc.test", %{}, old)
    frame = %{"type" => "user_upsert", "origin" => @origin, "user" => new_user}

    assert :ok = UserEvents.deliver(frame, old, changed, views)
    assert_sent_messages([{operator.pid, ":Remote!~remote@east.example NICK Renamed\r\n"}])
    assert_sent_messages_amount(viewer.pid, 0)

    quit_frame = %{"type" => "user_remove", "origin" => @origin, "uid" => @uid}
    assert :ok = UserEvents.deliver(quit_frame, old, %{old | users: %{}, members: %{}}, views)
    assert_sent_messages([{operator.pid, ":Remote!~remote@east.example QUIT :Client Quit\r\n"}])
    assert_sent_messages_amount(viewer.pid, 0)
  end

  test "route loss sends one QUIT per visible local client before clearing the old view" do
    {viewer, first} = local_channel("#split")
    Memento.transaction!(fn -> insert(:user_monitor, user: viewer, target_nick: "Remote") end)
    old = remote_state([first])
    views = ChannelView.select("irc.test", %{}, old)

    assert :ok = UserEvents.deliver_departures(old, Replica.new(), views, "Server link lost")

    assert_sent_messages([
      {viewer.pid, ":Remote!~remote@east.example QUIT :Server link lost\r\n"},
      {viewer.pid, ":irc.test 731 Viewer :Remote\r\n"}
    ])
  end

  test "a replacement snapshot sends a nickname change for a retained UID" do
    {viewer, channel} = local_channel("#resync")
    old = remote_state([channel])
    user = old.users[{@origin, @uid}]
    renamed = %{user | "nick" => "Renamed"}
    current = %{old | users: %{{@origin, @uid} => renamed}}
    views = ChannelView.select("irc.test", %{}, old)
    frame = %{"type" => "snapshot_end", "origin" => @origin}

    assert :ok = UserEvents.deliver(frame, old, current, views)
    assert_sent_messages([{viewer.pid, ":Remote!~remote@east.example NICK Renamed\r\n"}])
  end

  defp local_channel(name) do
    Memento.transaction!(fn ->
      viewer = insert(:user, nick: "Viewer")
      channel = insert(:channel, name: name)
      insert(:user_channel, user: viewer, channel: channel)
      {viewer, channel}
    end)
  end

  defp remote_state(channels, modes \\ ["o"]) do
    user = build(:user, nick: "Remote", ident: "~remote", hostname: @origin, realname: "Remote user")
    payload = UserPayload.from_local(user, @uid)

    remote_channels = Map.new(channels, &{{@origin, &1.name_key}, ChannelPayload.from_local(&1, @origin)})

    remote_members =
      Map.new(channels, fn channel ->
        {{@origin, {channel.name_key, @uid}},
         %{
           "channel" => channel.name,
           "uid" => @uid,
           "modes" => modes,
           "joined_at" => DateTime.to_iso8601(DateTime.utc_now())
         }}
      end)

    %{Replica.new() | users: %{{@origin, @uid} => payload}, channels: remote_channels, members: remote_members}
  end
end
