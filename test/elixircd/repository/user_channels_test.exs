defmodule ElixIRCd.Repository.UserChannelsTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repository.UserChannels
  alias ElixIRCd.Tables.UserChannel

  describe "create/1" do
    test "creates a new user channel" do
      port = Port.open({:spawn, "cat /dev/null"}, [:binary])

      attrs = %{
        user_port: port,
        user_socket: port,
        user_transport: :ranch_tcp,
        channel_name: "#elixir",
        modes: []
      }

      user_channel = Memento.transaction!(fn -> UserChannels.create(attrs) end)

      assert user_channel.user_port == port
      assert user_channel.user_socket == port
      assert user_channel.user_transport == :ranch_tcp
      assert user_channel.channel_name == "#elixir"
      assert user_channel.modes == []
    end
  end

  describe "delete/1" do
    test "deletes a user channel" do
      user_channel = insert(:user_channel)

      Memento.transaction!(fn -> UserChannels.delete(user_channel) end)

      assert nil == Memento.transaction!(fn -> Memento.Query.read(UserChannel, user_channel.user_port) end)
    end
  end

  describe "delete_by_user_port/1" do
    test "deletes user channels by user port" do
      user = insert(:user)
      insert(:user_channel, user: user)
      insert(:user_channel, user: user)

      Memento.transaction!(fn -> UserChannels.delete_by_user_port(user.port) end)

      assert [] ==
               Memento.transaction!(fn ->
                 Memento.Query.select(UserChannel, {:==, :user_port, user.port})
               end)
    end
  end

  describe "get_by_user_port_and_channel_name/2" do
    test "returns a user channel by user port and channel name" do
      user_channel = insert(:user_channel)

      assert {:ok, user_channel} ==
               Memento.transaction!(fn ->
                 UserChannels.get_by_user_port_and_channel_name(user_channel.user_port, user_channel.channel_name)
               end)
    end

    test "returns an error when the user channel is not found" do
      user = insert(:user)

      assert {:error, "UserChannel not found"} ==
               Memento.transaction!(fn ->
                 UserChannels.get_by_user_port_and_channel_name(user.port, "#elixir")
               end)
    end
  end

  describe "get_by_user_port/1" do
    test "returns user channels by user port" do
      user = insert(:user)
      insert(:user_channel, user: user)
      insert(:user_channel, user: user)

      assert [%UserChannel{}, %UserChannel{}] = Memento.transaction!(fn -> UserChannels.get_by_user_port(user.port) end)
    end
  end

  describe "get_by_channel_name/1" do
    test "returns user channels by channel name" do
      channel = insert(:channel)
      insert(:user_channel, channel: channel)
      insert(:user_channel, channel: channel)

      assert [%UserChannel{}, %UserChannel{}] =
               Memento.transaction!(fn -> UserChannels.get_by_channel_name(channel.name) end)
    end
  end

  describe "get_by_channel_names/1" do
    test "returns user channels by channel names" do
      channel1 = insert(:channel)
      channel2 = insert(:channel)
      insert(:user_channel, channel: channel1)
      insert(:user_channel, channel: channel2)

      assert [%UserChannel{}, %UserChannel{}] =
               Memento.transaction!(fn -> UserChannels.get_by_channel_names([channel1.name, channel2.name]) end)
    end
  end
end
