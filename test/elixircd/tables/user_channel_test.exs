defmodule ElixIRCd.Tables.UserChannelTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Tables.UserChannel

  describe "new/1" do
    test "creates a new user channel with default values" do
      port = Port.open({:spawn, "cat /dev/null"}, [:binary])
      utc_now = DateTime.utc_now()

      attrs = %{
        user_port: port,
        user_socket: port,
        user_transport: :ranch_tcp,
        channel_name: "test"
      }

      user_channel = UserChannel.new(attrs)

      assert user_channel.user_port == port
      assert user_channel.user_socket == port
      assert user_channel.user_transport == :ranch_tcp
      assert user_channel.channel_name == "test"
      assert user_channel.modes == []
      assert DateTime.diff(utc_now, user_channel.created_at) < 1000
    end

    test "creates a new user channel with custom values" do
      utc_now = DateTime.utc_now()
      port = Port.open({:spawn, "cat /dev/null"}, [:binary])

      attrs = %{
        user_port: port,
        user_socket: port,
        user_transport: :ranch_tcp,
        channel_name: "test",
        modes: [],
        created_at: utc_now
      }

      user_channel = UserChannel.new(attrs)

      assert user_channel.user_port == port
      assert user_channel.user_socket == port
      assert user_channel.user_transport == :ranch_tcp
      assert user_channel.channel_name == "test"
      assert user_channel.modes == []
      assert user_channel.created_at == utc_now
    end
  end

  describe "update/2" do
    test "updates a user channel with new values" do
      port = Port.open({:spawn, "cat /dev/null"}, [:binary])

      user_channel =
        UserChannel.new(%{
          user_port: port,
          user_socket: port,
          user_transport: :ranch_tcp,
          channel_name: "test"
        })

      updated_user_channel = UserChannel.update(user_channel, %{modes: [{:a, "test"}]})

      assert updated_user_channel.user_port == port
      assert updated_user_channel.user_socket == port
      assert updated_user_channel.user_transport == :ranch_tcp
      assert updated_user_channel.channel_name == "test"
      assert updated_user_channel.modes == [{:a, "test"}]
      assert updated_user_channel.created_at == user_channel.created_at
    end
  end
end
