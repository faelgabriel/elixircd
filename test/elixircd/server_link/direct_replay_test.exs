defmodule ElixIRCd.ServerLink.DirectReplayTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias ElixIRCd.ServerLink.DirectReplay
  alias ElixIRCd.ServerLink.DirectReplay.Entry

  test "retains a typed decision for exact duplicates but rejects reused IDs with other content" do
    frame = frame("east", "epoch", "one")
    cache = DirectReplay.new(max_entries: 2, ttl_ms: 10)

    assert {:new, cache} = DirectReplay.check(cache, frame, 100)
    cache = DirectReplay.remember(cache, frame, "accept_only", nil, 100)
    assert {:duplicate, %Entry{code: "accept_only", away: nil}, ^cache} = DirectReplay.check(cache, frame, 101)
    assert {:duplicate, %Entry{}, ^cache} = DirectReplay.check(cache, %{frame | "ttl" => 63}, 101)
    assert {:conflict, ^cache} = DirectReplay.check(cache, %{frame | "text" => "different"}, 101)
    assert {:conflict, ^cache} = DirectReplay.check(cache, %{frame | "sent_at" => "later"}, 101)
  end

  test "bounds entries by capacity and age while separating origin epochs" do
    first = frame("east", "epoch", "one")
    second = frame("west", "epoch", "one")
    third = frame("east", "epoch", "two")
    cache = DirectReplay.new(max_entries: 2, ttl_ms: 10)
    cache = DirectReplay.remember(cache, first, "ok", "Away", 100)
    cache = DirectReplay.remember(cache, second, "silent", nil, 101)
    cache = DirectReplay.remember(cache, third, "unknown_target", nil, 102)

    assert {:new, ^cache} = DirectReplay.check(cache, first, 103)
    assert {:duplicate, %Entry{code: "silent"}, ^cache} = DirectReplay.check(cache, second, 103)
    assert {:new, _cache} = DirectReplay.check(cache, frame("east", "next_epoch", "two"), 103)
    assert {:new, _cache} = DirectReplay.check(cache, third, 113)
  end

  defp frame(origin, epoch, id) do
    %{
      "origin" => origin,
      "epoch" => epoch,
      "id" => id,
      "from_uid" => "sender",
      "to_origin" => "irc.test",
      "to_uid" => "recipient",
      "command" => "PRIVMSG",
      "text" => "hello",
      "tags" => %{},
      "sent_at" => "now",
      "ttl" => 64
    }
  end
end
