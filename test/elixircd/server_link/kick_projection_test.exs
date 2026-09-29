defmodule ElixIRCd.ServerLink.KickProjectionTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Kick
  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.ChannelView.RemoteMember
  alias ElixIRCd.ServerLink.Directory
  alias ElixIRCd.ServerLink.Frame
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.KickMutation.Outbound
  alias ElixIRCd.ServerLink.Projector
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.ChannelKickMarker
  alias ElixIRCd.Tables.RegisteredChannel.Settings

  setup do
    prior_links = Application.fetch_env!(:elixircd, :server_links)
    Application.put_env(:elixircd, :server_links, Keyword.put(prior_links, :enabled, true))
    on_exit(fn -> Application.put_env(:elixircd, :server_links, prior_links) end)
    :ok
  end

  test "a committed local KICK is projected as a typed removal cause" do
    {operator, target, channel} =
      Memento.transaction!(fn ->
        operator = insert(:user, nick: "Operator")
        target = insert(:user, nick: "Target")
        channel = insert(:channel, name: "#shared")
        insert(:user_channel, user: operator, channel: channel, modes: [:o])
        insert(:user_channel, user: target, channel: channel)
        {operator, target, channel}
      end)

    table = ChannelDirectory.create()
    payload = ChannelPayload.from_local(channel)
    view = %ChannelView{origin: "irc.test", channel: payload, remote_present: false}
    ChannelDirectory.sync(table, %{}, %{channel.name_key => view})
    Directory.create()

    projector = start_supervised!({Projector, [name: nil, id: "irc.test"]})
    :ok = Projector.subscribe(projector, self())
    {:ok, actor_uid} = Projector.uid_for_pid(projector, operator.pid)
    {:ok, target_uid} = Projector.uid_for_pid(projector, target.pid)

    Memento.transaction!(fn ->
      Kick.handle(operator, %Message{command: "KICK", params: [channel.name, target.nick], trailing: "Reason"})
    end)

    Projector.refresh_snapshot(projector)
    assert_receive {:server_link_local_delta, frames}
    assert Enum.all?(frames, &(Frame.validate(&1) == :ok))

    assert Enum.any?(frames, fn
             %{
               "type" => "delta_entry",
               "field" => "member",
               "action" => "remove",
               "entry" => %{"uid" => ^target_uid},
               "kick" => %{"actor_origin" => "irc.test", "actor_uid" => ^actor_uid, "reason" => "Reason"}
             } ->
               true

             _ ->
               false
           end)

    assert Memento.transaction!(fn -> Memento.Query.all(ChannelKickMarker) end) == []

    assert Memento.transaction!(fn -> UserChannels.get_by_user_pid_and_channel_name(target.pid, channel.name) end) ==
             {:error, :user_channel_not_found}
  end

  test "KICK fails closed when the configured channel index is unavailable" do
    {operator, target, channel} =
      Memento.transaction!(fn ->
        operator = insert(:user, nick: "Operator")
        target = insert(:user, nick: "Target")
        channel = insert(:channel, name: "#shared")
        insert(:user_channel, user: operator, channel: channel, modes: [:o])
        insert(:user_channel, user: target, channel: channel)
        {operator, target, channel}
      end)

    Memento.transaction!(fn ->
      Kick.handle(operator, %Message{command: "KICK", params: [channel.name, target.nick]})
    end)

    assert_sent_message_contains(operator.pid, ~r/437 Operator #shared :Channel membership is temporarily unavailable/)

    assert {:ok, _membership} =
             Memento.transaction!(fn -> UserChannels.get_by_user_pid_and_channel_name(target.pid, channel.name) end)
  end

  test "KICK of a remote member queues a typed request only after the command commits" do
    {operator, channel, remote_uid} = remote_kick_fixture()
    assert Process.whereis(Hub) == nil
    Process.register(self(), Hub)

    Observability.transaction(fn ->
      Kick.handle(operator, %Message{command: "KICK", params: [channel.name, "Remote"], trailing: "Reason"})
      refute_receive {:"$gen_cast", _}
    end)

    assert_receive {:"$gen_cast",
                    {:request_kick,
                     %Outbound{
                       sender_pid: sender_pid,
                       target_origin: "east.example",
                       target_uid: ^remote_uid,
                       target_nick: "Remote",
                       channel: "#shared",
                       reason: "Reason"
                     }}}

    assert sender_pid == operator.pid
  end

  test "registered local channel does not queue a remote KICK without shared services authority" do
    {operator, channel, _remote_uid} = remote_kick_fixture()

    Memento.transaction!(fn ->
      insert(:registered_channel, name: channel.name, founder: "founder", settings: Settings.new(%{}))
    end)

    assert Process.whereis(Hub) == nil
    Process.register(self(), Hub)

    Observability.transaction(fn ->
      Kick.handle(operator, %Message{command: "KICK", params: [channel.name, "Remote"], trailing: "Reason"})
    end)

    assert_sent_message_contains(operator.pid, ~r/437 Operator #shared :Channel membership is temporarily unavailable/)
    refute_receive {:"$gen_cast", {:request_kick, _request}}
  end

  test "projector restart discards markers for memberships absent from its initial snapshot" do
    Memento.transaction!(fn ->
      target = insert(:user, nick: "Target")

      ChannelKickMarker.local("#old", target.pid, DateTime.utc_now(), target.pid, "irc.test", "Target!u@h", "old")
      |> Memento.Query.write()
    end)

    _projector = start_supervised!({Projector, [name: nil, id: "irc.test"]})
    assert Memento.transaction!(fn -> Memento.Query.all(ChannelKickMarker) end) == []
  end

  test "a kick followed by a new membership before refresh emits removal and rejoin" do
    {operator, target, channel, old_membership} =
      Memento.transaction!(fn ->
        operator = insert(:user, nick: "Operator")
        target = insert(:user, nick: "Target")
        channel = insert(:channel, name: "#shared")
        insert(:user_channel, user: operator, channel: channel, modes: [:o])
        old_membership = insert(:user_channel, user: target, channel: channel)
        {operator, target, channel, old_membership}
      end)

    table = ChannelDirectory.create()
    Directory.create()
    view = %ChannelView{origin: "irc.test", channel: ChannelPayload.from_local(channel), remote_present: false}
    ChannelDirectory.sync(table, %{}, %{channel.name_key => view})

    projector = start_supervised!({Projector, [name: nil, id: "irc.test"]})
    :ok = Projector.subscribe(projector, self())
    {:ok, target_uid} = Projector.uid_for_pid(projector, target.pid)

    Memento.transaction!(fn ->
      Kick.handle(operator, %Message{command: "KICK", params: [channel.name, target.nick], trailing: "Reason"})

      insert(:user_channel,
        user: target,
        channel: channel,
        created_at: DateTime.add(old_membership.created_at, 1, :second)
      )
    end)

    Projector.refresh_snapshot(projector)
    assert_receive {:server_link_local_delta, frames}
    assert Enum.count(frames, &match?(%{"field" => "member", "action" => "remove"}, &1)) == 1

    assert Enum.any?(frames, fn
             %{"field" => "member", "action" => "remove", "entry" => %{"uid" => ^target_uid}, "kick" => _} ->
               true

             _ ->
               false
           end)

    assert Enum.any?(frames, fn
             %{"field" => "member", "action" => "upsert", "entry" => %{"uid" => ^target_uid}} -> true
             _ -> false
           end)
  end

  defp remote_kick_fixture do
    {operator, channel} =
      Memento.transaction!(fn ->
        operator = insert(:user, nick: "Operator")
        channel = insert(:channel, name: "#shared")
        insert(:user_channel, user: operator, channel: channel, modes: [:o])
        {operator, channel}
      end)

    remote_uid = UserPayload.new_uid()
    remote = build(:user, nick: "Remote") |> UserPayload.from_local(remote_uid)

    replica = %Replica{
      users: %{{"east.example", remote_uid} => remote},
      nick_keys: %{"remote" => {"east.example", remote_uid}}
    }

    directory = Directory.create()
    Directory.sync(directory, Replica.new(), replica)
    table = ChannelDirectory.create()

    view = %ChannelView{
      origin: "irc.test",
      channel: ChannelPayload.from_local(channel),
      remote_present: true,
      remote_members: [
        %RemoteMember{origin: "east.example", member: %{"uid" => remote_uid}, user: remote, effective_modes: []}
      ]
    }

    ChannelDirectory.sync(table, %{}, %{channel.name_key => view})
    {operator, channel, remote_uid}
  end
end
