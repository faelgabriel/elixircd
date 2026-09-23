defmodule ElixIRCd.Server.S2S.SyncTest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.JSON
  alias ElixIRCd.Server.S2S.Sync

  test "captures dependency ordered rows and verifies page digest" do
    sync_id = Identity.nonce()

    topology = %{
      "kind" => "topology.remove",
      "edge_id" => String.duplicate("a", 64),
      "reporter" => "root",
      "reason" => "split"
    }

    channel = %{"kind" => "channel.ensure", "channel" => %{"name" => "#chat", "born_ms" => 1, "cid" => Identity.cid()}}

    assert {:ok, snapshot} = Sync.capture(sync_id, 8, %{topology: [topology], channels: [channel]}, page_size: 1)
    assert {:ok, %{frames: frames, bodies: bodies, digest: digest}} = Sync.frames(snapshot)
    assert hd(frames)["phase"] == "begin"
    assert List.last(frames)["phase"] == "end"
    assert length(bodies) == 2
    assert List.last(frames)["sha256"] == digest
    assert {:ok, verified} = Sync.verify(frames)
    assert verified.rows == [topology, channel]
    assert verified.digest == digest

    page_frames = frames |> Enum.drop(1) |> Enum.drop(-1)
    with_bodies = [hd(frames) | Enum.zip(page_frames, bodies)] ++ [List.last(frames)]
    assert {:ok, verified_with_bodies} = Sync.verify(with_bodies)
    assert verified_with_bodies.digest == digest
    assert Enum.any?(bodies, &String.contains?(&1, JSON.encode(topology)))
  end

  test "staging waits for every page and rejects a digest mismatch" do
    row = %{"kind" => "channel.ensure", "channel" => %{"name" => "#chat", "born_ms" => 1, "cid" => Identity.cid()}}
    {:ok, snapshot} = Sync.capture(Identity.nonce(), 1, %{channels: [row]})
    {:ok, %{frames: [begin, page, ending]}} = Sync.frames(snapshot)

    staging = Sync.new_staging(begin["sync_id"])
    assert {:ok, staging} = Sync.stage(staging, begin, JSON.encode(begin))
    assert {:ok, staging} = Sync.stage(staging, page, JSON.encode(page))
    assert {:error, :snapshot_digest_mismatch} = Sync.finish(staging, %{ending | "sha256" => String.duplicate("0", 64)})
    assert {:ok, result} = Sync.finish(staging, ending)
    assert result.rows == [row]
  end

  test "dependency inversion and duplicate pages are bounded failures" do
    topology = %{
      "kind" => "topology.remove",
      "edge_id" => String.duplicate("a", 64),
      "reporter" => "root",
      "reason" => "split"
    }

    channel = %{"kind" => "channel.ensure", "channel" => %{"name" => "#chat", "born_ms" => 1, "cid" => Identity.cid()}}
    {:ok, snapshot} = Sync.capture(Identity.nonce(), 1, %{topology: [topology], channels: [channel]})
    {:ok, %{frames: [begin, page, ending]}} = Sync.frames(snapshot)
    inverted = %{snapshot | rows: [channel, topology]}
    assert {:ok, %{frames: inverted_frames}} = Sync.frames(inverted)
    assert {:error, :dependency_order} = Sync.verify(inverted_frames)

    staging = Sync.new_staging(begin["sync_id"])
    assert {:ok, staging} = Sync.stage(staging, begin, nil)
    assert {:ok, staging} = Sync.stage(staging, page, nil)
    assert {:error, :duplicate_page} = Sync.stage(staging, page, nil)
    assert ending["pages"] == 1
  end
end
