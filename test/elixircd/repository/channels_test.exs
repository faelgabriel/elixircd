defmodule ElixIRCd.Repository.ChannelsTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repository.Channels

  describe "create/1" do
    test "creates a new channel" do
      attrs = %{
        name: "#elixir",
        topic: "Elixir programming language",
        modes: []
      }

      channel = Memento.transaction!(fn -> Channels.create(attrs) end)

      assert channel.name == "#elixir"
      assert channel.topic == "Elixir programming language"
      assert channel.modes == []
    end
  end

  describe "get_by_name/1" do
    test "returns a channel by name" do
      channel = insert(:channel)

      assert {:ok, channel} == Memento.transaction!(fn -> Channels.get_by_name(channel.name) end)
    end
  end
end
