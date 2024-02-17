defmodule ElixIRCd.Tables.ChannelTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Tables.Channel

  describe "new/1" do
    test "creates a new channel with default values" do
      attrs = %{
        name: "test"
      }

      channel = Channel.new(attrs)

      assert channel.name == "test"
      assert channel.topic == nil
      assert channel.modes == []
      assert DateTime.diff(DateTime.utc_now(), channel.created_at) < 1000
    end

    test "creates a new channel with custom values" do
      utc_now = DateTime.utc_now()

      attrs = %{
        name: "test",
        topic: "This is a test topic",
        modes: [],
        created_at: utc_now
      }

      channel = Channel.new(attrs)

      assert channel.name == "test"
      assert channel.topic == "This is a test topic"
      assert channel.modes == []
      assert channel.created_at == utc_now
    end
  end

  describe "update/2" do
    test "updates a channel with new values" do
      channel = Channel.new(%{name: "test"})

      updated_channel = Channel.update(channel, %{topic: "This is a test topic", modes: [{:a, "test"}]})

      assert updated_channel.name == "test"
      assert updated_channel.topic == "This is a test topic"
      assert updated_channel.modes == [{:a, "test"}]
      assert updated_channel.created_at == channel.created_at
    end
  end
end
