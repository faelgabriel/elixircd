defmodule ElixIRCd.ServerLink.ProjectorTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Factory
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.ServerLink.Frame
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.Projector
  alias ElixIRCd.ServerLink.Projector.Overflow
  alias ElixIRCd.Tables.User
  alias Memento.Query.Data

  setup do
    projector = start_supervised!({Projector, [name: nil, id: "east.example"]})
    :ok = Projector.subscribe(projector, self())
    %{projector: projector}
  end

  test "only committed registered users enter the ordered stream", %{projector: projector} do
    user = Factory.build(:user, nick: "Alice")

    assert {:error, {:transaction_aborted, :cancelled}} =
             Memento.transaction(fn ->
               Memento.Query.write(user)
               Memento.Transaction.abort(:cancelled)
             end)

    refute_receive {:server_link_local_event, _}, 100
    assert Projector.snapshot(projector).users == []

    Memento.transaction!(fn -> Memento.Query.write(user) end)
    assert_receive {:server_link_local_event, %{"type" => "user_upsert", "sequence" => 1, "user" => payload}}
    assert payload["nick"] == "Alice"
    refute Map.has_key?(payload, "pid")
    assert %{cursor: 1, users: [^payload]} = Projector.snapshot(projector)

    Memento.transaction!(fn -> Memento.Query.write(%{user | last_activity: user.last_activity + 1}) end)
    refute_receive {:server_link_local_event, _}, 100
    assert Projector.snapshot(projector).cursor == 1

    Memento.transaction!(fn -> Memento.Query.write(%{user | nick: "Bob"}) end)
    assert_receive {:server_link_local_event, %{"type" => "user_upsert", "sequence" => 2, "user" => changed}}
    assert changed["uid"] == payload["uid"]
    assert changed["nick"] == "Bob"

    Memento.transaction!(fn -> Memento.Query.delete(User, user.pid) end)
    assert_receive {:server_link_local_event, %{"type" => "user_remove", "sequence" => 3, "uid" => uid}}
    assert uid == payload["uid"]
    assert %{cursor: 3, users: []} = Projector.snapshot(projector)
  end

  test "unregistered connections are not announced", %{projector: projector} do
    user = Factory.build(:user, registered: false, nick: nil)
    Memento.transaction!(fn -> Memento.Query.write(user) end)
    refute_receive {:server_link_local_event, _}, 100
    assert Projector.snapshot(projector).users == []
  end

  test "a stalled subscriber receives one overflow signal and must rebuild from a snapshot", %{projector: projector} do
    stalled =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(stalled, :kill) end)
    assert :ok = Projector.subscribe(projector, stalled, max_queue: 1)

    first = Factory.build(:user, nick: "First")
    Memento.transaction!(fn -> Memento.Query.write(first) end)
    assert_receive {:server_link_local_event, %{"sequence" => 1}}

    second = Factory.build(:user, nick: "Second")
    Memento.transaction!(fn -> Memento.Query.write(second) end)
    assert_receive {:server_link_local_event, %{"sequence" => 2}}
    assert %{cursor: 2} = Projector.snapshot(projector)

    assert {:messages,
            [
              {:server_link_local_event, %{"sequence" => 1}},
              {:server_link_projector_overflow, %Overflow{sequence: 2} = overflow}
            ]} = Process.info(stalled, :messages)

    third = Factory.build(:user, nick: "Third")
    Memento.transaction!(fn -> Memento.Query.write(third) end)
    assert_receive {:server_link_local_event, %{"sequence" => 3}}
    assert {:messages, [_, {:server_link_projector_overflow, ^overflow}]} = Process.info(stalled, :messages)
    assert {:stop, :projector_overflow, %{}} = Hub.handle_info({:server_link_projector_overflow, overflow}, %{})

    assert %{cursor: 3, users: users} = Projector.snapshot(projector)
    assert Enum.sort(Enum.map(users, & &1["nick"])) == ["First", "Second", "Third"]

    recovered =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(recovered, :kill) end)
    assert :ok = Projector.subscribe(projector, recovered, max_queue: 1)

    fourth = Factory.build(:user, nick: "Fourth")
    Memento.transaction!(fn -> Memento.Query.write(fourth) end)
    assert_receive {:server_link_local_event, %{"sequence" => 4}}
    assert %{cursor: 4} = Projector.snapshot(projector)
    assert {:messages, [{:server_link_local_event, %{"sequence" => 4}}]} = Process.info(recovered, :messages)
  end

  test "an overloaded Mnesia event inbox restarts the projector" do
    child =
      Supervisor.child_spec({Projector, [name: nil, id: "limited.example", max_inbound_queue: 1]},
        id: :limited_projector
      )

    limited = start_supervised!(child)
    ref = Process.monitor(limited)
    :ok = :sys.suspend(limited)

    for _ <- 1..3 do
      send(limited, {:mnesia_table_event, {:write, ElixIRCd.Tables.Channel, nil, nil, nil}})
    end

    :ok = :sys.resume(limited)
    assert_receive {:DOWN, ^ref, :process, ^limited, :projector_input_overflow}
  end

  test "a delayed stale user event cannot restore an older nickname", %{projector: projector} do
    original = Factory.build(:user, nick: "Alice")
    Memento.transaction!(fn -> Memento.Query.write(original) end)
    assert_receive {:server_link_local_event, %{"type" => "user_upsert", "user" => %{"uid" => uid}}}

    Memento.transaction!(fn -> Memento.Query.write(%{original | nick: "Bob"}) end)
    assert {:ok, ^uid} = Projector.uid_for_pid(projector, original.pid)
    assert_receive {:server_link_local_event, %{"type" => "user_upsert", "user" => %{"nick" => "Bob"}}}

    send(projector, {:mnesia_table_event, {:write, User, Data.dump(original), nil, nil}})
    assert [%{"nick" => "Bob", "uid" => ^uid}] = Projector.snapshot(projector).users
    refute_receive {:server_link_local_event, %{"user" => %{"nick" => "Alice"}}}, 50
  end

  test "a committed channel snapshot includes local members, lists and invites", %{projector: projector} do
    user = Factory.build(:user, nick: "Alice")
    Memento.transaction!(fn -> Memento.Query.write(user) end)
    assert_receive {:server_link_local_event, %{"type" => "user_upsert", "user" => %{"uid" => uid}}}

    channel = Factory.build(:channel, name: "#shared", modes: [:n])
    local_only = Factory.build(:channel, name: "&local")
    member = Factory.build(:user_channel, user_pid: user.pid, channel_name_key: channel.name_key, modes: [:o])
    ban = Factory.build(:channel_ban, channel_name_key: channel.name_key, mask: "*!*@example.test")
    invite = Factory.build(:channel_invite, user_pid: user.pid, channel_name_key: channel.name_key)

    Memento.transaction!(fn ->
      Enum.each([channel, local_only, member, ban, invite], &Memento.Query.write/1)
    end)

    assert_receive {:server_link_local_delta, frames}
    assert %{"type" => "delta_begin", "count" => 4} = hd(frames)
    assert %{"type" => "delta_end"} = List.last(frames)
    snapshot = Projector.snapshot(projector)
    assert [%{"name" => "#shared", "modes" => [%{"name" => "n"}]}] = snapshot.channels
    assert [%{"channel" => "#shared", "uid" => ^uid}] = snapshot.members
    assert [%{"channel" => "#shared", "kind" => "b"}] = snapshot.lists
    assert [%{"channel" => "#shared", "uid" => ^uid}] = snapshot.invites

    Memento.transaction!(fn -> Memento.Query.delete_record(ban) end)

    assert_receive {:server_link_local_delta,
                    [
                      %{"type" => "delta_begin", "count" => 1},
                      %{"field" => "list", "action" => "remove"},
                      %{"type" => "delta_end"}
                    ]}

    assert Projector.snapshot(projector).lists == []
  end

  test "an adopted channel keeps its original creation server in the wire record", %{projector: projector} do
    Memento.transaction!(fn -> Channels.create(%{name: "#adopted", creator: "remote.example"}) end)

    assert_receive {:server_link_local_delta,
                    [
                      %{"type" => "delta_begin"},
                      %{"field" => "channel", "entry" => %{"creator" => "remote.example"}},
                      %{"type" => "delta_end"}
                    ]}

    assert [%{"name" => "#adopted", "creator" => "remote.example"}] = Projector.snapshot(projector).channels
  end

  test "a large committed channel change is split into bounded ordered deltas", %{projector: projector} do
    stalled =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(stalled, :kill) end)
    assert :ok = Projector.subscribe(projector, stalled, max_queue: 1)

    Memento.transaction!(fn ->
      for number <- 1..(Frame.max_delta_entries() + 1) do
        Factory.build(:channel, name: "#bulk#{number}") |> Memento.Query.write()
      end
    end)

    assert_receive {:server_link_local_delta, [%{"type" => "delta_begin", "sequence" => 1, "count" => 1_024} | first]},
                   5_000

    assert length(first) == 1_025

    assert_receive {:server_link_local_delta, [%{"type" => "delta_begin", "sequence" => 2, "count" => 1} | second]},
                   5_000

    assert length(second) == 2
    assert %{cursor: 2, channels: channels} = Projector.snapshot(projector)
    assert length(channels) == 1_025

    assert {:messages,
            [
              {:server_link_local_delta, [%{"type" => "delta_begin", "sequence" => 1} | _]},
              {:server_link_projector_overflow, %Overflow{sequence: 2}}
            ]} = Process.info(stalled, :messages)
  end
end
