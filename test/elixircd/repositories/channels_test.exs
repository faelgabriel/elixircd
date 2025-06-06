defmodule ElixIRCd.Repositories.ChannelsTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Tables.Channel

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

  describe "delete/1" do
    test "deletes a channel" do
      channel = insert(:channel)

      assert :ok == Memento.transaction!(fn -> Channels.delete(channel) end)
      assert {:error, :channel_not_found} == Memento.transaction!(fn -> Channels.get_by_name(channel.name) end)
    end
  end

  describe "delete_by_name/1" do
    test "deletes a channel by name" do
      channel = insert(:channel)

      assert :ok == Memento.transaction!(fn -> Channels.delete_by_name(channel.name) end)
      assert {:error, :channel_not_found} == Memento.transaction!(fn -> Channels.get_by_name(channel.name) end)
    end
  end

  describe "get_by_name/1" do
    test "returns a channel by name" do
      channel = insert(:channel)

      assert {:ok, channel} == Memento.transaction!(fn -> Channels.get_by_name(channel.name) end)
    end
  end

  describe "get_by_names/1" do
    test "returns channels by names" do
      channel1 = insert(:channel, name: "#elixir")
      channel2 = insert(:channel, name: "#phoenix")
      insert(:channel, name: "#other")

      assert [%Channel{}, %Channel{}] =
               Memento.transaction!(fn -> Channels.get_by_names([channel1.name, channel2.name]) end)
    end

    test "returns an empty list when no channel names are provided" do
      assert [] == Memento.transaction!(fn -> Channels.get_by_names([]) end)
    end
  end

  describe "count_all/0" do
    test "returns the total number of channels" do
      insert(:channel)
      insert(:channel)

      assert 2 == Memento.transaction!(fn -> Channels.count_all() end)
    end
  end
end
