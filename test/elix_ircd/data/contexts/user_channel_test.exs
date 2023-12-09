defmodule ElixIRCd.Contexts.UserChannelTest do
  @moduledoc false

  use ElixIRCd.DataCase
  doctest ElixIRCd.Contexts.UserChannel

  alias Ecto.Changeset
  alias ElixIRCd.Contexts.UserChannel
  alias ElixIRCd.Data.Schemas

  import ElixIRCd.Factory

  describe "create/1" do
    test "creates a user_channel with valid attributes" do
      user = insert(:user)
      channel = insert(:channel)
      new_attrs = %{user_socket: user.socket, channel_name: channel.name}

      assert {:ok, %Schemas.UserChannel{} = user_channel} = UserChannel.create(new_attrs)
      assert user_channel.user_socket == user.socket
      assert user_channel.channel_name == channel.name
    end

    test "fails to create a user_channel with invalid attributes" do
      new_attrs = %{user_socket: nil, channel_name: nil}

      assert {:error, %Changeset{} = changeset} = UserChannel.create(new_attrs)
      assert length(changeset.errors) == 2
      assert changeset.errors[:user_socket] == {"can't be blank", [validation: :required]}
      assert changeset.errors[:channel_name] == {"can't be blank", [validation: :required]}
    end
  end

  describe "update/2" do
    test "updates a user_channel with valid attributes" do
      user_channel = insert(:user_channel)
      new_user = insert(:user)
      new_channel = insert(:channel)
      new_attrs = %{user_socket: new_user.socket, channel_name: new_channel.name}

      assert {:ok, %Schemas.UserChannel{} = updated_user_channel} = UserChannel.update(user_channel, new_attrs)
      assert updated_user_channel.channel_name == new_attrs.channel_name
    end

    test "fails to update a user_channel with invalid attributes" do
      user_channel = insert(:user_channel)
      new_attrs = %{user_socket: nil, channel_name: nil}

      assert {:error, %Changeset{} = changeset} = UserChannel.update(user_channel, new_attrs)
      assert length(changeset.errors) == 2
      assert changeset.errors[:user_socket] == {"can't be blank", [validation: :required]}
      assert changeset.errors[:channel_name] == {"can't be blank", [validation: :required]}
    end
  end

  describe "delete/1" do
    test "deletes a user_channel" do
      user_channel = insert(:user_channel)

      assert {:ok, deleted_user_channel} = UserChannel.delete(user_channel)
      assert deleted_user_channel.user_socket == user_channel.user_socket
    end
  end

  describe "get_by_user/1" do
    test "gets all user_channels for a user" do
      user = insert(:user)
      insert_pair(:user_channel, user: user)

      assert length(UserChannel.get_by_user(user)) == 2
    end
  end

  describe "get_by_channel/1" do
    test "gets all user_channels for a channel" do
      channel = insert(:channel)
      insert_pair(:user_channel, channel: channel)

      assert length(UserChannel.get_by_channel(channel)) == 2
    end
  end

  describe "get_by_user_and_channel/2" do
    test "gets a user_channel for a user and channel" do
      user = insert(:user)
      channel = insert(:channel)
      insert(:user_channel, user: user, channel: channel)

      assert {:ok, user_channel} = UserChannel.get_by_user_and_channel(user, channel)
      assert user_channel.user_socket == user.socket
      assert user_channel.channel_name == channel.name
    end
  end
end
