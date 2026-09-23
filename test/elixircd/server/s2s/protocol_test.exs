defmodule ElixIRCd.Server.S2S.ProtocolTest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.JSON
  alias ElixIRCd.Server.S2S.Protocol

  test "decodes frames split at every transport boundary" do
    first = %{"t" => "ping", "n" => 1, "token" => Identity.nonce()}
    second = %{"t" => "pong", "n" => 2, "token" => first["token"]}
    wire = Protocol.encode!(first) <> Protocol.encode!(second)

    for split <- 0..byte_size(wire) do
      left = binary_part(wire, 0, split)
      right = binary_part(wire, split, byte_size(wire) - split)

      assert {:ok, first_frames, tail} = Protocol.feed(<<>>, left)
      assert {:ok, second_frames, <<>>} = Protocol.feed(tail, right)
      assert first_frames ++ second_frames == [first, second]
    end
  end

  test "keeps a coalesced incomplete tail" do
    ping = %{"t" => "ping", "n" => 1, "token" => Identity.nonce()}
    pong = %{"t" => "pong", "n" => 2, "token" => ping["token"]}
    pong_wire = Protocol.encode!(pong)
    partial = binary_part(pong_wire, 0, 3)

    assert {:ok, [^ping, ^pong], ^partial} = Protocol.feed(<<>>, Protocol.encode!(ping) <> pong_wire <> partial)
    assert Protocol.validate_sequence([ping, pong], 1) == :ok
  end

  test "re-evaluates the budget after a coalesced hello" do
    hello = %{
      "t" => "hello",
      "protocol" => "elixircd-native",
      "version" => 1,
      "network_id" => "test-network",
      "profile_hash" => String.duplicate("a", 64),
      "sid" => "root",
      "boot" => Identity.boot(),
      "name" => "root",
      "nonce" => Identity.nonce(),
      "time_ms" => 1_700_000_000_000
    }

    message = %{
      "t" => "message",
      "n" => 1,
      "origin" => %{"sid" => "root", "boot" => hello["boot"]},
      "actor" => %{"server" => "root"},
      "message_id" => Identity.nonce(),
      "sent_ms" => 1,
      "target" => %{"user" => Identity.uid()},
      "command" => "PRIVMSG",
      "text" => String.duplicate("x", 4_096),
      "tags" => %{},
      "request_id" => nil
    }

    hello_wire = Protocol.encode!(hello)
    message_wire = Protocol.encode!(message)
    assert byte_size(message_wire) - 4 > Protocol.body_limit("hello")

    assert {:ok, [{^hello, _hello_body}], tail} =
             Protocol.feed(<<>>, hello_wire <> message_wire,
               limit: Protocol.body_limit("hello"),
               include_bodies: true,
               max_frames: 1
             )

    assert {:ok, [{^message, _message_body}], <<>>} =
             Protocol.feed(tail, <<>>,
               limit: Protocol.body_limit("message"),
               include_bodies: true,
               max_frames: 1
             )
  end

  test "rejects an oversized declared body before waiting for it" do
    assert {:error, {:frame_too_large, 129, 128}} = Protocol.feed(<<>>, <<129::unsigned-big-32>>, limit: 128)
  end

  test "uses the larger bounded value budget only for topology frames" do
    assert Protocol.body_limit(%{"t" => "state", "changes" => [%{"kind" => "topology.add"}]}) == 1_048_576
    assert Protocol.body_limit(%{"t" => "state", "changes" => [%{"kind" => "user.put"}]}) == 65_536
  end

  test "enforces closed frame schemas" do
    frame = %{"t" => "ping", "n" => 1, "token" => Identity.nonce(), "extra" => true}

    assert {:error, {:field_set, _, _}} = ElixIRCd.Server.S2S.Schema.validate_frame(frame)
    assert {:error, :top_level_must_be_object} = Protocol.decode_body("[]")
  end

  test "accepts a valid sync page with its phase-specific fields" do
    sync_id = Identity.nonce()

    row = %{
      "kind" => "topology.remove",
      "edge_id" => String.duplicate("a", 64),
      "reporter" => "alpha",
      "reason" => "lost"
    }

    frame = %{
      "t" => "sync",
      "n" => 1,
      "phase" => "rows",
      "sync_id" => sync_id,
      "scope" => "network",
      "page" => 0,
      "rows" => [row]
    }

    assert {:ok, ^frame} = Protocol.decode_body(JSON.encode(frame))
  end
end
