defmodule ElixIRCd.ServerLink.SnapshotTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Factory
  alias ElixIRCd.ServerLink.Frame
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.Projector
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.Route
  alias ElixIRCd.ServerLink.Snapshot

  test "a local burst must fit the same count and byte budgets as its receiver" do
    empty = %Snapshot{origin: "east.example", epoch: String.duplicate("a", 32), cursor: 0, users: []}
    assert :ok = Snapshot.validate(empty, 1)

    user = %{"uid" => String.duplicate("b", 32)}
    one = %{empty | users: [user]}
    assert :ok = Snapshot.validate(one, :erlang.external_size(user))
    assert {:error, :local_snapshot_too_large} = Snapshot.validate(one, :erlang.external_size(user) - 1)

    too_many = %{empty | channels: List.duplicate(%{}, Frame.max_snapshot_entries() + 1)}
    assert {:error, :local_snapshot_too_large} = Snapshot.validate(too_many, 1_000_000)
  end

  test "the coordinator rejects an oversized local burst before attaching a peer" do
    user = Factory.build(:user, nick: "Alice")
    Memento.transaction!(fn -> Memento.Query.write(user) end)
    projector = start_supervised!({Projector, [name: nil, id: "irc.test"]})

    state = %{
      id: "irc.test",
      peers: %{"west.example" => %{id: "west.example"}},
      projector: projector,
      replica: Replica.new(max_snapshot_bytes: 1),
      links: %{},
      suppressed: MapSet.new()
    }

    assert {:reply, {:error, :local_snapshot_too_large}, ^state} =
             Hub.handle_call({:register, "west.example", :outbound, self()}, {self(), make_ref()}, state)
  end

  test "a committed origin snapshot is not sent back to a server already in its path" do
    parent = self()
    ancestor = spawn(fn -> collect(parent, :ancestor) end)
    downstream = spawn(fn -> collect(parent, :downstream) end)

    on_exit(fn ->
      Process.exit(ancestor, :kill)
      Process.exit(downstream, :kill)
    end)

    origin = "a.example"
    epoch = String.duplicate("a", 32)
    path = [origin, "c.example", "b.example", "d.example"]
    route = %Route{via: "b.example", epoch: epoch, path: path}
    begin_frame = %{"type" => "snapshot_begin", "origin" => origin, "epoch" => epoch, "cursor" => 0, "count" => 0}
    end_frame = %{"type" => "snapshot_end", "origin" => origin, "epoch" => epoch}
    {:ok, staging} = Replica.apply(Replica.new(), begin_frame)

    state = %Hub.State{
      id: "d.example",
      network: "test-network",
      replays: Hub.ReplayCaches.new(),
      local_epoch: String.duplicate("f", 32),
      links: %{"b.example" => self(), "c.example" => ancestor, "z.example" => downstream},
      routes: %{origin => route},
      replica: staging,
      local_channels: %{},
      channel_authorities: %{},
      channel_view: %{},
      indexes: %Hub.Indexes{}
    }

    assert {:reply, :ok, updated} =
             Hub.handle_call({:remote_frame, "b.example", self(), end_frame}, {self(), make_ref()}, state)

    assert_receive {:downstream, {:link_frame, %{"type" => "route_up", "origin" => ^origin, "path" => ^path}}}
    assert_receive {:downstream, {:link_snapshot, %Snapshot{origin: ^origin, cursor: 0}}}
    refute_receive {:ancestor, _}

    register_state =
      Map.merge(updated, %{
        peers: %{"c.example" => %{id: "c.example"}},
        links: Map.delete(updated.links, "c.example"),
        projector: nil,
        local_epoch: String.duplicate("d", 32),
        local_cursor: 0,
        pending: %{},
        pending_refs: %{},
        link_refs: %{},
        link_cursors: %{},
        suppressed: MapSet.new()
      })

    assert {:reply, :ok, _registered} =
             Hub.handle_call({:register, "c.example", :inbound, self()}, {self(), make_ref()}, register_state)

    assert_receive {:link_frame, %{"type" => "route_up", "origin" => "d.example"}}
    assert_receive {:link_snapshot, %Snapshot{origin: "d.example"}}
    refute_receive {:link_frame, %{"type" => "route_up", "origin" => ^origin}}
    refute_receive {:link_snapshot, %Snapshot{origin: ^origin}}
  end

  defp collect(parent, label) do
    receive do
      message ->
        send(parent, {label, message})
        collect(parent, label)
    end
  end
end
