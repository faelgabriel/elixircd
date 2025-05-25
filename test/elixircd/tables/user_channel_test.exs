defmodule ElixIRCd.Tables.UserChannelTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Tables.UserChannel

  describe "new/1" do
    test "creates a new user channel with default values" do
      pid = spawn(fn -> :ok end)
      utc_now = DateTime.utc_now()

      attrs = %{
        user_pid: pid,
        user_transport: :tcp,
        channel_name_key: "test"
      }

      user_channel = UserChannel.new(attrs)

      assert user_channel.user_pid == pid
      assert user_channel.user_transport == :tcp
      assert user_channel.channel_name_key == "test"
      assert user_channel.modes == []
      assert DateTime.diff(utc_now, user_channel.created_at) < 1000
    end

    test "creates a new user channel with custom values" do
      pid = spawn(fn -> :ok end)
      utc_now = DateTime.utc_now()

      attrs = %{
        user_pid: pid,
        user_transport: :tcp,
        channel_name_key: "test",
        modes: [],
        created_at: utc_now
      }

      user_channel = UserChannel.new(attrs)

      assert user_channel.user_pid == pid
      assert user_channel.user_transport == :tcp
      assert user_channel.channel_name_key == "test"
      assert user_channel.modes == []
      assert user_channel.created_at == utc_now
    end
  end

  describe "update/2" do
    test "updates a user channel with new values" do
      pid = spawn(fn -> :ok end)

      user_channel =
        UserChannel.new(%{
          user_pid: pid,
          user_transport: :tcp,
          channel_name_key: "test"
        })

      updated_user_channel = UserChannel.update(user_channel, %{modes: [{:a, "test"}]})

      assert updated_user_channel.user_pid == pid
      assert updated_user_channel.user_transport == :tcp
      assert updated_user_channel.channel_name_key == "test"
      assert updated_user_channel.modes == [{:a, "test"}]
      assert updated_user_channel.created_at == user_channel.created_at
    end
  end
end
