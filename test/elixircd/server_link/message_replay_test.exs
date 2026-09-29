defmodule ElixIRCd.ServerLink.MessageReplayTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias ElixIRCd.ServerLink.MessageReplay

  test "one origin and epoch cannot replay a message within the bounded window" do
    window = MessageReplay.new(max_entries: 2, ttl_ms: 10)
    assert {:new, window} = MessageReplay.accept(window, "east", "epoch", "one", 100)
    assert {:duplicate, window} = MessageReplay.accept(window, "east", "epoch", "one", 101)
    assert {:new, window} = MessageReplay.accept(window, "west", "epoch", "one", 102)
    assert {:new, window} = MessageReplay.accept(window, "east", "epoch", "two", 103)
    assert map_size(window.entries) == 2
    assert {:new, window} = MessageReplay.accept(window, "east", "epoch", "one", 104)
    assert map_size(window.entries) == 2
    assert {:new, _window} = MessageReplay.accept(window, "east", "new-epoch", "one", 105)
  end

  test "expired IDs are removed without growing the retained map" do
    window = MessageReplay.new(max_entries: 2, ttl_ms: 10)
    assert {:new, window} = MessageReplay.accept(window, "east", "epoch", "one", 100)
    assert {:new, window} = MessageReplay.accept(window, "east", "epoch", "two", 111)
    assert map_size(window.entries) == 1
    assert {:new, window} = MessageReplay.accept(window, "east", "epoch", "one", 112)
    assert map_size(window.entries) == 2
  end
end
