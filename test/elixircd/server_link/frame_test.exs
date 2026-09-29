defmodule ElixIRCd.ServerLink.FrameTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias ElixIRCd.ServerLink.Frame

  test "encodes and decodes one complete greeting while preserving following bytes" do
    greeting = Frame.hello("east.example", "My Network")
    assert {:ok, encoded} = Frame.encode(greeting)
    assert :more = Frame.decode_one(binary_part(encoded, 0, byte_size(encoded) - 1))
    assert {:ok, ^greeting, <<1, 2, 3>>} = Frame.decode_one(encoded <> <<1, 2, 3>>)
  end

  test "rejects unknown types, extra keys, malformed identity and invalid nonces" do
    greeting = Frame.hello("east.example", "My Network")

    for invalid <- [
          Map.put(greeting, "type", "event"),
          Map.put(greeting, "extra", "value"),
          Map.put(greeting, "id", "bad host"),
          Map.put(greeting, "nonce", "short"),
          Map.put(greeting, "version", 1),
          Map.put(greeting, "case_mapping", "unknown"),
          %{"type" => "ping", "sequence" => -1},
          %{"type" => "pong", "sequence" => 9_007_199_254_740_992}
        ] do
      assert {:error, :invalid_frame} = Frame.encode(invalid)
    end
  end

  test "rejects oversized length before waiting for its body" do
    assert {:error, :frame_too_large} = Frame.decode_one(<<Frame.max_bytes() + 1::unsigned-32>>)
    assert {:error, :invalid_frame} = Frame.decode_one(<<0::unsigned-32>>)
  end

  test "rejects malformed JSON even when its length is valid" do
    assert {:error, :invalid_frame} = Frame.decode_one(<<3::unsigned-32, "no!">>)
  end

  test "route paths have canonical origin and cannot repeat a server" do
    epoch = String.duplicate("1", 32)
    good = %{"type" => "route_up", "origin" => "a.example", "epoch" => epoch, "path" => ["a.example", "b.example"]}
    assert :ok = Frame.validate(good)

    for path <- [[], ["b.example"], ["a.example", "a.example"], ["a.example", "BAD HOST"]] do
      assert {:error, :invalid_frame} = Frame.validate(%{good | "path" => path})
    end
  end

  test "channel deltas have a fixed batch limit and closed entry fields" do
    epoch = String.duplicate("1", 32)
    begin_frame = %{"type" => "delta_begin", "origin" => "a.example", "epoch" => epoch, "sequence" => 1, "count" => 1}
    assert :ok = Frame.validate(begin_frame)
    assert {:error, :invalid_frame} = Frame.validate(%{begin_frame | "count" => Frame.max_delta_entries() + 1})

    entry = %{
      "type" => "delta_entry",
      "origin" => "a.example",
      "epoch" => epoch,
      "field" => "unknown",
      "action" => "upsert",
      "entry" => %{}
    }

    assert {:error, :invalid_frame} = Frame.validate(entry)
  end

  test "snapshot declarations bound the aggregate number of staged records" do
    epoch = String.duplicate("1", 32)

    frame = %{
      "type" => "snapshot_begin",
      "origin" => "a.example",
      "epoch" => epoch,
      "cursor" => 0,
      "count" => Frame.max_snapshot_entries(),
      "channel_count" => 0,
      "member_count" => 0,
      "list_count" => 0,
      "invite_count" => 0
    }

    assert :ok = Frame.validate(frame)
    assert {:error, :invalid_frame} = Frame.validate(%{frame | "channel_count" => 1})
  end

  test "direct messages reject forged fields, controls and server-only tags" do
    uid = String.duplicate("1", 32)

    message = %{
      "type" => "direct_message",
      "origin" => "a.example",
      "epoch" => uid,
      "from_uid" => uid,
      "to_origin" => "b.example",
      "to_uid" => uid,
      "command" => "PRIVMSG",
      "text" => "hello",
      "tags" => %{"+draft/example" => "ok"},
      "ttl" => 64,
      "id" => uid,
      "sent_at" => "2026-09-29T14:00:00.000Z"
    }

    assert :ok = Frame.validate(message)
    assert {:error, :invalid_frame} = Frame.validate(%{message | "text" => "bad\r\n"})
    assert {:error, :invalid_frame} = Frame.validate(%{message | "tags" => %{"account" => "spoof"}})
    assert {:error, :invalid_frame} = Frame.validate(%{message | "ttl" => 0})
    assert {:error, :invalid_frame} = Frame.validate(%{message | "command" => "KILL"})
    assert {:error, :invalid_frame} = Frame.validate(%{message | "sent_at" => "invalid"})
  end

  test "direct results have a closed identity, bounded TTL and delivery code" do
    uid = String.duplicate("1", 32)

    result = %{
      "type" => "direct_result",
      "origin" => "b.example",
      "epoch" => uid,
      "to_origin" => "a.example",
      "to_uid" => uid,
      "id" => uid,
      "code" => "unknown_target",
      "away" => nil,
      "ttl" => 64
    }

    assert :ok = Frame.validate(result)
    assert :ok = Frame.validate(%{result | "code" => "registered_only"})
    assert :ok = Frame.validate(%{result | "code" => "accept_only"})
    assert :ok = Frame.validate(%{result | "code" => "silent"})
    assert :ok = Frame.validate(%{result | "code" => "ok", "away" => "Back later"})
    assert :ok = Frame.validate(%{result | "code" => "ok", "away" => String.duplicate("🌿", 400)})
    assert {:error, :invalid_frame} = Frame.validate(%{result | "code" => "ok", "away" => String.duplicate("a", 401)})

    assert {:error, :invalid_frame} =
             Frame.validate(%{result | "code" => "ok", "away" => String.duplicate("🌿", 401)})

    assert {:ok, encoded} = Frame.encode(result)
    assert {:ok, ^result, <<>>} = Frame.decode_one(encoded)

    for invalid <- [
          %{result | "code" => "accepted_elsewhere"},
          %{result | "ttl" => 0},
          %{result | "to_uid" => "bad"},
          %{result | "away" => "leak"},
          %{result | "code" => "ok", "away" => "bad\r\nline"},
          Map.put(result, "target_nick", "forged")
        ] do
      assert {:error, :invalid_frame} = Frame.validate(invalid)
    end
  end

  test "routed topic requests and results keep a closed authenticated shape" do
    uid = String.duplicate("1", 32)

    request = %{
      "type" => "topic_request",
      "origin" => "a.example",
      "epoch" => uid,
      "from_uid" => uid,
      "to_origin" => "b.example",
      "channel" => "#shared",
      "text" => "New topic",
      "id" => uid,
      "ttl" => 64
    }

    result = %{
      "type" => "topic_result",
      "origin" => "b.example",
      "epoch" => uid,
      "to_origin" => "a.example",
      "to_uid" => uid,
      "channel" => "#shared",
      "id" => uid,
      "code" => "ok",
      "ttl" => 64
    }

    assert :ok = Frame.validate(request)
    assert :ok = Frame.validate(result)

    for invalid <- [
          %{request | "text" => "bad\r\nline"},
          %{request | "ttl" => 0},
          %{request | "channel" => "&local"},
          Map.put(request, "account", "spoofed"),
          %{result | "code" => "granted"},
          %{result | "to_uid" => "bad"},
          Map.put(result, "text", "spoofed")
        ] do
      assert {:error, :invalid_frame} = Frame.validate(invalid)
    end
  end

  test "routed metadata mode frames reject extra fields and unsafe arguments" do
    uid = String.duplicate("1", 32)

    request = %{
      "type" => "mode_request",
      "origin" => "a.example",
      "epoch" => uid,
      "from_uid" => uid,
      "to_origin" => "b.example",
      "channel" => "#shared",
      "modes" => "+nt",
      "values" => [],
      "id" => uid,
      "ttl" => 64
    }

    result = %{
      "type" => "mode_result",
      "origin" => "b.example",
      "epoch" => uid,
      "to_origin" => "a.example",
      "to_uid" => uid,
      "channel" => "#shared",
      "id" => uid,
      "code" => "ok",
      "ttl" => 64
    }

    assert :ok = Frame.validate(request)
    assert :ok = Frame.validate(result)

    assert :ok =
             Frame.validate(%{
               request
               | "modes" => "+" <> String.duplicate("k", 20),
                 "values" => List.duplicate("x", 20)
             })

    assert {:error, :invalid_frame} = Frame.validate(%{request | "values" => ["bad\r\n"]})
    assert {:error, :invalid_frame} = Frame.validate(%{request | "values" => List.duplicate("x", 65)})
    assert {:error, :invalid_frame} = Frame.validate(%{request | "modes" => "bad mode"})
    assert {:error, :invalid_frame} = Frame.validate(Map.put(request, "extra", "unsafe"))
    assert {:error, :invalid_frame} = Frame.validate(%{result | "code" => "force"})
  end
end
