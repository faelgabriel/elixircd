defmodule ElixIRCd.Contexts.ChannelTest do
  @moduledoc false

  use ElixIRCd.DataCase
  doctest ElixIRCd.Contexts.Channel

  alias Ecto.Changeset
  alias ElixIRCd.Contexts.Channel
  alias ElixIRCd.Data.Repo
  alias ElixIRCd.Data.Schemas

  @valid_attrs %{name: "#channel", topic: "Channel topic"}
  @invalid_attrs %{name: "channel"}

  describe "create/1" do
    test "creates a channel with valid attributes" do
      assert {:ok, %Schemas.Channel{} = channel} = Channel.create(@valid_attrs)
      assert channel.name == "#channel"
    end

    test "fails to create a channel with invalid attributes" do
      assert {:error, %Changeset{} = changeset} = Channel.create(@invalid_attrs)
      assert changeset.errors[:name] == {"Channel name must start with a hash mark (#)", []}
    end
  end

  describe "update/2" do
    test "updates a channel with valid attributes" do
      {:ok, channel} = Channel.create(@valid_attrs)
      assert {:ok, %Schemas.Channel{} = updated_channel} = Channel.update(channel, %{topic: "New topic"})
      assert updated_channel.topic == "New topic"
    end
  end

  describe "delete/1" do
    test "deletes a channel" do
      {:ok, channel} = Channel.create(@valid_attrs)
      assert {:ok, deleted_channel} = Channel.delete(channel)
      assert deleted_channel.name == channel.name
      assert Repo.get(Schemas.Channel, channel.name) == nil
    end
  end

  describe "get_by_name/1" do
    test "gets a channel by name" do
      {:ok, channel} = Channel.create(@valid_attrs)
      assert Channel.get_by_name(channel.name) == channel
    end

    test "returns nil if no channel is found" do
      assert Channel.get_by_name("nonexistent") == nil
    end
  end
end
