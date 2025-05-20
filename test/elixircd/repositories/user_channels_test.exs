defmodule ElixIRCd.Repositories.UserChannelsTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Tables.UserChannel

  describe "create/1" do
    test "creates a new user channel" do
      pid = spawn(fn -> :ok end)

      attrs = %{
        user_pid: pid,
        user_transport: :tcp,
        channel_name_key: "#elixir",
        modes: []
      }

      user_channel = Memento.transaction!(fn -> UserChannels.create(attrs) end)

      assert user_channel.user_pid == pid
      assert user_channel.user_transport == :tcp
      assert user_channel.channel_name_key == "#elixir"
      assert user_channel.modes == []
    end
  end

  describe "update/2" do
    test "updates a user channel" do
      user_channel = insert(:user_channel)
      user_channel = Memento.transaction!(fn -> UserChannels.update(user_channel, %{modes: ["o"]}) end)
      assert user_channel.modes == ["o"]
    end
  end

  describe "delete/1" do
    test "deletes a user channel" do
      user_channel = insert(:user_channel)
      Memento.transaction!(fn -> UserChannels.delete(user_channel) end)
      assert nil == Memento.transaction!(fn -> Memento.Query.read(UserChannel, user_channel.user_pid) end)
    end
  end

  describe "delete_by_user_pid/1" do
    test "deletes user channels by user pid" do
      user = insert(:user)
      insert(:user_channel, user: user)
      insert(:user_channel, user: user)

      Memento.transaction!(fn -> UserChannels.delete_by_user_pid(user.pid) end)

      assert [] ==
               Memento.transaction!(fn ->
                 Memento.Query.select(UserChannel, {:==, :user_pid, user.pid})
               end)
    end
  end

  describe "get_by_user_pid_and_channel_name/2" do
    test "returns a user channel by user pid and channel name" do
      user_channel = insert(:user_channel)

      assert {:ok, user_channel} ==
               Memento.transaction!(fn ->
                 UserChannels.get_by_user_pid_and_channel_name(
                   user_channel.user_pid,
                   user_channel.channel_name_key
                 )
               end)
    end

    test "returns an error when the user channel is not found" do
      user = insert(:user)

      assert {:error, :user_channel_not_found} ==
               Memento.transaction!(fn ->
                 UserChannels.get_by_user_pid_and_channel_name(user.pid, "#elixir")
               end)
    end
  end

  describe "get_by_user_pid/1" do
    test "returns user channels by user pid" do
      user = insert(:user)
      insert(:user_channel, user: user)
      insert(:user_channel, user: user)

      assert [%UserChannel{}, %UserChannel{}] = Memento.transaction!(fn -> UserChannels.get_by_user_pid(user.pid) end)
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

  describe "count_users_by_channel_name/1" do
    test "returns the number of users in a channel by the channel name" do
      channel = insert(:channel)
      insert(:user_channel, channel: channel)
      insert(:user_channel, channel: channel)

      assert 2 == Memento.transaction!(fn -> UserChannels.count_users_by_channel_name(channel.name) end)
    end
  end

  describe "count_users_by_channel_names/1" do
    test "returns the number of users in channels by the channel names" do
      channel1 = insert(:channel, name: "#channel1")
      channel2 = insert(:channel, name: "#channel2")
      insert(:user_channel, channel: channel1)
      insert(:user_channel, channel: channel2)
      insert(:user_channel, channel: channel2)

      assert [{"#channel1", 1}, {"#channel2", 2}] ==
               Memento.transaction!(fn ->
                 Enum.sort(UserChannels.count_users_by_channel_names([channel1.name, channel2.name]))
               end)
    end
  end
end
