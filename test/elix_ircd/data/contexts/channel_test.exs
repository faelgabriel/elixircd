defmodule ElixIRCd.Contexts.ChannelTest do
  @moduledoc false

  use ElixIRCd.DataCase
  doctest ElixIRCd.Contexts.Channel

  alias Ecto.Changeset
  alias ElixIRCd.Contexts.Channel
  alias ElixIRCd.Data.Schemas

  import ElixIRCd.Factory

  describe "create/1" do
    test "creates a channel with valid attributes" do
      new_attrs = build(:channel) |> Map.from_struct()

      assert {:ok, %Schemas.Channel{} = channel} = Channel.create(new_attrs)
      assert channel.name == new_attrs.name
      assert channel.topic == new_attrs.topic
    end

    test "fails to create a channel with invalid attributes" do
      new_attrs = %{name: "_invalidname"}

      assert {:error, %Changeset{} = changeset} = Channel.create(new_attrs)
      assert length(changeset.errors) == 1
      assert changeset.errors[:name] == {"Channel name must start with a hash mark (#)", []}
    end
  end

  describe "update/2" do
    test "updates a channel with valid attributes" do
      channel = insert(:channel)
      new_attrs = %{topic: "newtopic"}

      assert {:ok, %Schemas.Channel{} = updated_channel} = Channel.update(channel, new_attrs)
      assert updated_channel.topic == new_attrs.topic
    end

    test "fails to update a channel with invalid attributes" do
      channel = insert(:channel)
      new_attrs = %{name: "_invalidname"}

      assert {:error, %Changeset{} = changeset} = Channel.update(channel, new_attrs)
      assert length(changeset.errors) == 1
      assert changeset.errors[:name] == {"Channel name must start with a hash mark (#)", []}
    end
  end

  describe "delete/1" do
    test "deletes a channel" do
      channel = insert(:channel)

      assert {:ok, %Schemas.Channel{} = deleted_channel} = Channel.delete(channel)
      assert deleted_channel.name == channel.name
    end
  end

  describe "get_by_name/1" do
    test "gets a channel by name" do
      channel = insert(:channel)

      assert {:ok, %Schemas.Channel{} = fetched_channel} = Channel.get_by_name(channel.name)
      assert fetched_channel.name == channel.name
    end

    test "returns error if no channel is found" do
      assert {:error, "Channel not found"} = Channel.get_by_name("nonexistent")
    end
  end

  describe "get_by_name_with_users/1" do
    test "gets a channel by name and preloads its users" do
      channel = insert(:channel)
      user = insert(:user)
      insert(:user_channel, user: user, channel: channel)

      assert {:ok, %Schemas.Channel{} = fetched_channel} = Channel.get_by_name_with_users(channel.name)
      assert length(fetched_channel.user_channels) == 1
      assert fetched_channel.user_channels |> Enum.any?(fn uc -> uc.user_socket == user.socket end)
    end

    test "returns error if no channel is found" do
      assert {:error, "Channel not found"} = Channel.get_by_name_with_users("nonexistent")
    end
  end
end
