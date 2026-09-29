defmodule ElixIRCd.ServerLink.ReplicaTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias ElixIRCd.Factory
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.Frame
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.UserPayload

  @origin "east.example"
  @epoch "11111111111111111111111111111111"
  @uid "22222222222222222222222222222222"

  test "a complete snapshot becomes visible atomically and advances its cursor" do
    user = payload()
    replica = Replica.new()
    assert :error = Replica.get_by_nick(replica, "Alice")

    {:ok, staging} = Replica.apply(replica, begin_frame(1, 7))
    {:ok, staging} = Replica.apply(staging, item_frame(user))
    assert :error = Replica.get_by_nick(staging, "Alice")

    {:ok, committed} = Replica.apply(staging, end_frame())
    assert {:ok, ^user} = Replica.get_by_nick(committed, "ALICE")
    assert [^user] = Replica.users_from(committed, @origin)
    assert {:ok, %{epoch: @epoch, cursor: 7}} = Replica.origin_state(committed, @origin)
    assert {:error, :stale_snapshot} = Replica.apply(committed, begin_frame(1, 6))
  end

  test "incomplete, duplicate and overflowing snapshots never replace committed users" do
    user = payload()
    {:ok, first} = Replica.apply(Replica.new(), begin_frame(1, 0))
    assert {:error, :snapshot_incomplete} = Replica.apply(first, end_frame())
    assert :error = Replica.get_by_nick(first, "Alice")
    {:ok, first} = Replica.apply(first, item_frame(user))
    assert {:error, :duplicate_uid} = Replica.apply(first, item_frame(user))

    assert {:error, :snapshot_overflow} =
             Replica.apply(first, item_frame(%{user | "uid" => String.duplicate("3", 32), "nick" => "Bob"}))

    assert {:error, :snapshot_in_progress} = Replica.apply(first, begin_frame(0, 0))
    assert {:ok, committed} = Replica.apply(first, end_frame())

    {:ok, second} = Replica.apply(committed, begin_frame(1, 3))
    assert {:error, :snapshot_incomplete} = Replica.apply(second, end_frame())
    assert {:ok, ^user} = Replica.get_by_nick(second, "Alice")
    assert {:ok, %{cursor: 0}} = Replica.origin_state(second, @origin)
  end

  test "snapshot staging rejects records beyond its byte budget before commit" do
    first = payload()
    second = %{first | "uid" => String.duplicate("3", 32), "nick" => "Bob"}
    budget = :erlang.external_size(first)
    replica = Replica.new(max_snapshot_bytes: budget)
    {:ok, staging} = Replica.apply(replica, begin_frame(2, 0))
    {:ok, staging} = Replica.apply(staging, item_frame(first))

    assert {:error, :snapshot_too_large} = Replica.apply(staging, item_frame(second))
    assert staging.staging[@origin].bytes == budget
    assert {:error, :snapshot_incomplete} = Replica.apply(staging, end_frame())

    channel =
      Factory.build(:channel, name: "#bounded")
      |> ChannelPayload.from_local()

    begin_with_channel = Map.put(begin_frame(1, 0), "channel_count", 1)

    begin_with_channel =
      Map.merge(begin_with_channel, %{"member_count" => 0, "list_count" => 0, "invite_count" => 0})

    {:ok, staging} = Replica.apply(replica, begin_with_channel)
    {:ok, staging} = Replica.apply(staging, item_frame(first))

    channel_frame = %{"type" => "snapshot_channel", "origin" => @origin, "epoch" => @epoch, "channel" => channel}
    assert {:error, :snapshot_too_large} = Replica.apply(staging, channel_frame)
  end

  test "live user events obey the committed byte budget and release it on removal" do
    user = payload()
    budget = :erlang.external_size(user) + 16
    {:ok, replica} = Replica.apply(Replica.new(max_snapshot_bytes: budget), begin_frame(1, 0))
    {:ok, replica} = Replica.apply(replica, item_frame(user))
    {:ok, replica} = Replica.apply(replica, end_frame())

    oversized = %{user | "realname" => String.duplicate("x", 300)}
    assert {:error, :origin_state_too_large} = Replica.apply(replica, upsert_frame(oversized, 1))
    assert {:ok, %{cursor: 0}} = Replica.origin_state(replica, @origin)

    {:ok, removed} = Replica.apply(replica, remove_frame(1))
    assert removed.usage[@origin] == %{count: 0, bytes: 0}

    another = %{user | "uid" => String.duplicate("3", 32), "nick" => "Bob"}
    assert {:ok, added} = Replica.apply(removed, upsert_frame(another, 2))
    assert {:ok, ^another} = Replica.get_by_nick(added, "Bob")
  end

  test "the global replica budget limits multiple origins and is released on a split" do
    first = payload()
    second = %{first | "nick" => "Bob"}
    budget = :erlang.external_size(first) + 16
    base = Replica.new(max_network_bytes: budget)
    {:ok, first_origin} = Replica.apply(base, begin_frame(1, 0))
    {:ok, first_origin} = Replica.apply(first_origin, item_frame(first))
    {:ok, first_origin} = Replica.apply(first_origin, end_frame())

    second_origin = "west.example"
    second_begin = Map.put(begin_frame(1, 0), "origin", second_origin)
    second_item = Map.put(item_frame(second), "origin", second_origin)
    second_end = Map.put(end_frame(), "origin", second_origin)
    {:ok, staging} = Replica.apply(first_origin, second_begin)

    assert {:error, :network_state_too_large} = Replica.apply(staging, second_item)
    assert staging.total_bytes == :erlang.external_size(first)
    assert staging.staged_bytes == 0

    after_split = Replica.drop_origin(staging, @origin)
    assert after_split.total_bytes == 0
    {:ok, after_split} = Replica.apply(after_split, second_item)
    assert {:ok, committed} = Replica.apply(after_split, second_end)
    assert {:ok, ^second} = Replica.get_by_nick(committed, "Bob")

    {:ok, staged_first} = Replica.apply(base, begin_frame(1, 0))
    {:ok, staged_first} = Replica.apply(staged_first, item_frame(first))
    {:ok, staged_both} = Replica.apply(staged_first, second_begin)
    assert {:error, :network_state_too_large} = Replica.apply(staged_both, second_item)
    assert staged_both.staged_bytes == :erlang.external_size(first)
    assert Replica.drop_origin(staged_both, @origin).staged_bytes == 0

    {:ok, empty_first} = Replica.apply(base, begin_frame(0, 0))
    {:ok, empty_first} = Replica.apply(empty_first, end_frame())
    {:ok, staged_second} = Replica.apply(empty_first, second_begin)
    {:ok, staged_second} = Replica.apply(staged_second, second_item)
    assert {:error, :network_state_too_large} = Replica.apply(staged_second, upsert_frame(first, 1))

    empty_begin = Map.put(second_begin, "count", 0)
    {:ok, empty_second} = Replica.apply(first_origin, empty_begin)
    {:ok, empty_second} = Replica.apply(empty_second, second_end)
    live = Map.put(upsert_frame(second, 1), "origin", second_origin)
    assert {:error, :network_state_too_large} = Replica.apply(empty_second, live)
    assert {:ok, freed} = empty_second |> Replica.drop_origin(@origin) |> Replica.apply(live)
    assert {:ok, ^second} = Replica.get_by_nick(freed, "Bob")
  end

  test "live changes require the exact epoch and next sequence" do
    user = payload()
    {:ok, replica} = Replica.apply(Replica.new(), begin_frame(1, 4))
    {:ok, replica} = Replica.apply(replica, item_frame(user))
    {:ok, replica} = Replica.apply(replica, end_frame())

    assert {:error, :sequence_gap} = Replica.apply(replica, upsert_frame(%{user | "nick" => "Bob"}, 7))

    assert {:error, :stale_epoch} =
             Replica.apply(replica, %{upsert_frame(user, 5) | "epoch" => String.duplicate("4", 32)})

    changed_registration = %{user | "registered_at" => "2026-09-27T00:00:00Z"}
    assert {:error, :registration_changed} = Replica.apply(replica, upsert_frame(changed_registration, 5))
    assert {:ok, ^user} = Replica.get_by_nick(replica, "Alice")

    {:ok, changed} = Replica.apply(replica, upsert_frame(%{user | "nick" => "Bob"}, 5))
    assert :error = Replica.get_by_nick(changed, "Alice")
    assert {:ok, %{"nick" => "Bob"}} = Replica.get_by_nick(changed, "bob")
    assert {:error, :sequence_gap} = Replica.apply(changed, upsert_frame(user, 5))

    {:ok, removed} = Replica.apply(changed, remove_frame(6))
    assert :error = Replica.get_by_nick(removed, "Bob")
    assert {:error, :unknown_uid} = Replica.apply(removed, remove_frame(7))
  end

  test "local nick claims do not reject an authenticated remote snapshot" do
    user = payload()
    {:ok, staging} = Replica.apply(Replica.new(), begin_frame(1, 0))

    assert {:error, :snapshot_not_started} =
             Replica.apply(staging, %{item_frame(user) | "epoch" => String.duplicate("4", 32)})

    {:ok, staging} = Replica.apply(staging, item_frame(user))

    assert {:error, :snapshot_not_started} =
             Replica.apply(staging, %{end_frame() | "epoch" => String.duplicate("4", 32)})

    assert {:ok, committed} = Replica.apply(staging, end_frame())
    assert :error = Replica.get_by_nick(staging, "Alice")
    assert {:ok, ^user} = Replica.get_by_nick(committed, "Alice")
  end

  test "cross-origin nick collisions keep both UIDs and promote the next claim after removal" do
    alice = payload()
    west_origin = "west.example"
    west_epoch = String.duplicate("4", 32)
    west_uid = String.duplicate("5", 32)
    older = %{alice | "uid" => west_uid, "registered_at" => "2026-09-28T00:00:00Z"}

    {:ok, east} = Replica.apply(Replica.new(), begin_frame(1, 0))
    {:ok, east} = Replica.apply(east, item_frame(alice))
    {:ok, east} = Replica.apply(east, end_frame())

    west_begin = %{begin_frame(1, 0) | "origin" => west_origin, "epoch" => west_epoch}
    west_item = %{item_frame(older) | "origin" => west_origin, "epoch" => west_epoch}
    west_end = %{end_frame() | "origin" => west_origin, "epoch" => west_epoch}
    {:ok, staging} = Replica.apply(east, west_begin)
    {:ok, staging} = Replica.apply(staging, west_item)
    {:ok, both} = Replica.apply(staging, west_end)

    assert map_size(both.users) == 2
    assert {:ok, ^older} = Replica.get_by_nick(both, "Alice")
    assert {:ok, ^alice} = Replica.get_by_uid(both, @origin, @uid)

    west_remove = %{remove_frame(1) | "origin" => west_origin, "epoch" => west_epoch, "uid" => west_uid}
    {:ok, promoted} = Replica.apply(both, west_remove)
    assert {:ok, ^alice} = Replica.get_by_nick(promoted, "Alice")

    colliding = %{alice | "uid" => String.duplicate("6", 32)}
    assert {:error, :nick_collision} = Replica.apply(promoted, upsert_frame(colliding, 1))
  end

  test "incremental nick changes select and release the winning cross-origin claim" do
    alice = payload()
    west_origin = "west.example"
    west_epoch = String.duplicate("4", 32)
    west_uid = String.duplicate("5", 32)
    older = %{alice | "uid" => west_uid, "registered_at" => "2026-09-28T00:00:00Z"}

    {:ok, east} = Replica.apply(Replica.new(), begin_frame(1, 0))
    {:ok, east} = Replica.apply(east, item_frame(alice))
    {:ok, east} = Replica.apply(east, end_frame())

    west_begin = %{begin_frame(0, 0) | "origin" => west_origin, "epoch" => west_epoch}
    west_end = %{end_frame() | "origin" => west_origin, "epoch" => west_epoch}
    {:ok, west_stage} = Replica.apply(east, west_begin)
    {:ok, both} = Replica.apply(west_stage, west_end)

    west_upsert = %{upsert_frame(older, 1) | "origin" => west_origin, "epoch" => west_epoch}
    {:ok, collided} = Replica.apply(both, west_upsert)
    assert {:ok, ^older} = Replica.get_by_nick(collided, "Alice")
    assert MapSet.size(collided.nick_claims["alice"]) == 2

    renamed = %{older | "nick" => "Bob"}
    {:ok, released} = Replica.apply(collided, %{west_upsert | "sequence" => 2, "user" => renamed})
    assert {:ok, ^alice} = Replica.get_by_nick(released, "Alice")
    assert {:ok, ^renamed} = Replica.get_by_nick(released, "Bob")
    assert MapSet.size(released.nick_claims["alice"]) == 1

    {:ok, reclaimed} = Replica.apply(released, %{west_upsert | "sequence" => 3})
    assert {:ok, ^older} = Replica.get_by_nick(reclaimed, "Alice")
    assert :error = Replica.get_by_nick(reclaimed, "Bob")

    west_remove = %{remove_frame(4) | "origin" => west_origin, "epoch" => west_epoch, "uid" => west_uid}
    {:ok, remaining} = Replica.apply(reclaimed, west_remove)
    assert {:ok, ^alice} = Replica.get_by_nick(remaining, "Alice")
  end

  test "dropping one origin discards its committed and partial users" do
    user = payload()
    {:ok, replica} = Replica.apply(Replica.new(), begin_frame(1, 0))
    {:ok, replica} = Replica.apply(replica, item_frame(user))
    {:ok, replica} = Replica.apply(replica, end_frame())
    {:ok, replica} = Replica.apply(replica, begin_frame(0, 1))

    empty = Replica.drop_origin(replica, @origin)
    assert :error = Replica.get_by_nick(empty, "Alice")
    assert :error = Replica.origin_state(empty, @origin)
    assert {:error, :snapshot_required} = Replica.apply(empty, upsert_frame(user, 1))
  end

  test "wire user schema strips local process and private connection state" do
    local = Factory.build(:user, nick: "Alice", hostname: "east.example", modes: [:i], identified_as: "Alice")
    user = UserPayload.from_local(local, @uid)
    assert :ok = UserPayload.validate(user)
    assert :ok = UserPayload.validate(%{user | "away" => String.duplicate("🌿", 400)})
    assert :ok = UserPayload.validate(%{user | "away" => " "})
    assert {:error, :invalid_user} = UserPayload.validate(%{user | "away" => String.duplicate("a", 401)})
    assert {:error, :invalid_user} = UserPayload.validate(%{user | "away" => String.duplicate("🌿", 401)})
    refute Map.has_key?(user, "pid")
    refute Map.has_key?(user, "ip_address")
    assert :ok = Frame.validate(item_frame(user))

    for invalid <- [
          Map.put(user, "pid", "fake"),
          Map.put(user, "uid", "bad"),
          Map.put(user, "nick", "bad nick"),
          Map.put(user, "modes", ["i", "i"]),
          Map.put(user, "modes", ["new_mode"]),
          Map.put(user, "registered_at", "yesterday")
        ] do
      assert {:error, :invalid_user} = UserPayload.validate(invalid)
      assert {:error, :invalid_frame} = Frame.validate(item_frame(invalid))
    end
  end

  test "channel entries commit atomically with users and require valid references" do
    channel = Factory.build(:channel, name: "#linked")
    metadata = ChannelPayload.from_local(channel)
    member = Factory.build(:user_channel) |> ChannelPayload.member_from_local(channel.name, @uid)
    list_entry = Factory.build(:channel_ban) |> ChannelPayload.list_from_local(channel.name, "b")
    invite = Factory.build(:channel_invite) |> ChannelPayload.invite_from_local(channel.name, @uid)

    begin_frame =
      begin_frame(1, 0)
      |> Map.merge(%{"channel_count" => 1, "member_count" => 1, "list_count" => 1, "invite_count" => 1})

    frames = [
      item_frame(payload()),
      %{"type" => "snapshot_channel", "origin" => @origin, "epoch" => @epoch, "channel" => metadata},
      %{"type" => "snapshot_member", "origin" => @origin, "epoch" => @epoch, "member" => member},
      %{"type" => "snapshot_list", "origin" => @origin, "epoch" => @epoch, "list" => list_entry},
      %{"type" => "snapshot_invite", "origin" => @origin, "epoch" => @epoch, "invite" => invite}
    ]

    {:ok, staging} = Replica.apply(Replica.new(), begin_frame)
    assert {:error, :snapshot_in_progress} = Replica.apply(staging, upsert_frame(payload(), 1))
    {:ok, staging} = Enum.reduce(frames, {:ok, staging}, fn frame, {:ok, replica} -> Replica.apply(replica, frame) end)
    assert Replica.channels_from(staging, @origin) == []
    assert {:error, :duplicate_channel_entry} = Replica.apply(staging, Enum.at(frames, 1))

    {:ok, committed} = Replica.apply(staging, end_frame())
    assert Replica.channels_from(committed, @origin) == [metadata]
    assert Replica.members_from(committed, @origin) == [member]
    assert Replica.lists_from(committed, @origin) == [list_entry]
    assert Replica.invites_from(committed, @origin) == [invite]
    assert Replica.channels_from(Replica.drop_origin(committed, @origin), @origin) == []

    {:ok, removed} = Replica.apply(committed, remove_frame(1))
    assert Replica.members_from(removed, @origin) == []
    assert Replica.invites_from(removed, @origin) == []
    assert removed.usage[@origin].count == 2

    {:ok, invalid} = Replica.apply(Replica.new(), begin_frame)
    wrong_member = %{member | "uid" => String.duplicate("3", 32)}
    invalid_frames = List.replace_at(frames, 2, %{Enum.at(frames, 2) | "member" => wrong_member})

    {:ok, invalid} =
      Enum.reduce(invalid_frames, {:ok, invalid}, fn frame, {:ok, replica} -> Replica.apply(replica, frame) end)

    assert {:error, :invalid_channel_reference} = Replica.apply(invalid, end_frame())
  end

  test "ordered channel deltas stage privately and reject gaps or incomplete batches" do
    metadata = Factory.build(:channel, name: "#linked") |> ChannelPayload.from_local()

    begin_frame =
      Map.merge(begin_frame(0, 0), %{"channel_count" => 1, "member_count" => 0, "list_count" => 0, "invite_count" => 0})

    channel_item = %{"type" => "snapshot_channel", "origin" => @origin, "epoch" => @epoch, "channel" => metadata}
    {:ok, replica} = Replica.apply(Replica.new(), begin_frame)
    {:ok, replica} = Replica.apply(replica, channel_item)
    {:ok, replica} = Replica.apply(replica, end_frame())

    updated = %{metadata | "modes" => [%{"name" => "n", "parameter" => nil}]}
    begin_delta = %{"type" => "delta_begin", "origin" => @origin, "epoch" => @epoch, "sequence" => 1, "count" => 1}

    entry = %{
      "type" => "delta_entry",
      "origin" => @origin,
      "epoch" => @epoch,
      "field" => "channel",
      "action" => "upsert",
      "entry" => updated
    }

    end_delta = %{"type" => "delta_end", "origin" => @origin, "epoch" => @epoch, "sequence" => 1}
    assert {:error, :sequence_gap} = Replica.apply(replica, %{begin_delta | "sequence" => 2})
    {:ok, staged} = Replica.apply(replica, begin_delta)
    assert Replica.channels_from(staged, @origin) == [metadata]
    assert {:error, :delta_incomplete} = Replica.apply(staged, end_delta)
    {:ok, staged} = Replica.apply(staged, entry)
    assert {:error, :delta_overflow} = Replica.apply(staged, entry)
    assert {:error, :snapshot_in_progress} = Replica.apply(staged, upsert_frame(payload(), 1))
    assert Replica.channels_from(staged, @origin) == [metadata]
    {:ok, committed} = Replica.apply(staged, end_delta)
    assert Replica.channels_from(committed, @origin) == [updated]
    assert {:ok, %{cursor: 1}} = Replica.origin_state(committed, @origin)

    remove = %{entry | "action" => "remove"}
    {:ok, staged} = Replica.apply(committed, %{begin_delta | "sequence" => 2})
    {:ok, staged} = Replica.apply(staged, remove)
    {:ok, removed} = Replica.apply(staged, %{end_delta | "sequence" => 2})
    assert Replica.channels_from(removed, @origin) == []
  end

  test "channel delta cannot grow committed state beyond the byte budget" do
    metadata = Factory.build(:channel, name: "#bounded") |> ChannelPayload.from_local()
    budget = :erlang.external_size(metadata)

    begin_with_channel =
      Map.merge(begin_frame(0, 0), %{
        "channel_count" => 1,
        "member_count" => 0,
        "list_count" => 0,
        "invite_count" => 0
      })

    channel_frame = %{"type" => "snapshot_channel", "origin" => @origin, "epoch" => @epoch, "channel" => metadata}
    {:ok, replica} = Replica.apply(Replica.new(max_snapshot_bytes: budget), begin_with_channel)
    {:ok, replica} = Replica.apply(replica, channel_frame)
    {:ok, replica} = Replica.apply(replica, end_frame())

    begin_delta = %{"type" => "delta_begin", "origin" => @origin, "epoch" => @epoch, "sequence" => 1, "count" => 1}
    updated = %{metadata | "modes" => [%{"name" => "n", "parameter" => nil}]}

    entry = %{
      "type" => "delta_entry",
      "origin" => @origin,
      "epoch" => @epoch,
      "field" => "channel",
      "action" => "upsert",
      "entry" => updated
    }

    end_delta = %{"type" => "delta_end", "origin" => @origin, "epoch" => @epoch, "sequence" => 1}
    {:ok, staged} = Replica.apply(replica, begin_delta)
    {:ok, staged} = Replica.apply(staged, entry)
    assert {:error, :origin_state_too_large} = Replica.apply(staged, end_delta)
    assert Replica.channels_from(replica, @origin) == [metadata]
  end

  defp payload do
    %{
      "uid" => @uid,
      "nick" => "Alice",
      "ident" => "~alice",
      "hostname" => "east.example",
      "cloaked_hostname" => nil,
      "realname" => "Alice Example",
      "modes" => ["i"],
      "account" => nil,
      "away" => nil,
      "registered_at" => "2026-09-29T00:00:00Z"
    }
  end

  defp begin_frame(count, cursor),
    do: %{"type" => "snapshot_begin", "origin" => @origin, "epoch" => @epoch, "count" => count, "cursor" => cursor}

  defp item_frame(user), do: %{"type" => "snapshot_user", "origin" => @origin, "epoch" => @epoch, "user" => user}
  defp end_frame, do: %{"type" => "snapshot_end", "origin" => @origin, "epoch" => @epoch}

  defp upsert_frame(user, sequence),
    do: %{"type" => "user_upsert", "origin" => @origin, "epoch" => @epoch, "sequence" => sequence, "user" => user}

  defp remove_frame(sequence),
    do: %{"type" => "user_remove", "origin" => @origin, "epoch" => @epoch, "sequence" => sequence, "uid" => @uid}
end
