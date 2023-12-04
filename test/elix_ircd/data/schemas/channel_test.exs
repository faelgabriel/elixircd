defmodule ElixIRCd.Data.Schemas.ChannelTest do
  @moduledoc false

  use ExUnit.Case, async: true
  doctest ElixIRCd.Data.Schemas.Channel

  alias ElixIRCd.Data.Schemas.Channel

  import ElixIRCd.Factory

  describe "changeset/2" do
    setup do
      channel = build(:channel)

      {:ok, channel: channel}
    end

    test "validates channel names correctly", %{channel: channel} do
      valid_names = ["#validChannel", "#another_one", "#channel123", "#another-one"]

      Enum.each(valid_names, fn name ->
        changeset = Channel.changeset(channel, %{name: name})
        assert changeset.valid? == true
        assert changeset.errors[:name] == nil
      end)

      invalid_names = ["#", "#channel@", "#channel!#", "#too-long-channel-name-that-exceeds-fifty-characters"]

      Enum.each(invalid_names, fn name ->
        changeset = Channel.changeset(channel, %{name: name})
        assert changeset.valid? == false
        assert changeset.errors[:name] == {"Invalid channel name format", []}
      end)

      changeset = Channel.changeset(channel, %{name: "InvalidChannel"})
      assert changeset.valid? == false
      assert changeset.errors[:name] == {"Channel name must start with a hash mark (#)", []}
    end
  end
end
