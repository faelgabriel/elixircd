defmodule ElixIRCd.FactoryTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Factory
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.HistoricalUser
  alias ElixIRCd.Tables.Metric
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  describe "build/2" do
    test "builds a user with default attributes" do
      assert %User{} = Factory.build(:user)
    end

    test "builds a user with custom attributes as a map" do
      assert %User{nick: "custom_nick"} = Factory.build(:user, %{nick: "custom_nick"})
    end

    test "builds a user with custom attributes as a keyword list" do
      assert %User{nick: "custom_nick"} = Factory.build(:user, nick: "custom_nick")
    end

    test "builds a channel with default attributes" do
      assert %Channel{} = Factory.build(:channel)
    end

    test "builds a channel with custom attributes as a map" do
      assert %Channel{name: "custom_name"} = Factory.build(:channel, %{name: "custom_name"})
    end

    test "builds a channel with custom attributes as a keyword list" do
      assert %Channel{name: "custom_name"} = Factory.build(:channel, name: "custom_name")
    end

    test "builds a user channel with default attributes" do
      assert %UserChannel{} = Factory.build(:user_channel)
    end

    test "builds a user channel with custom attributes as a map" do
      assert %UserChannel{channel_name: "custom_name"} = Factory.build(:user_channel, %{channel_name: "custom_name"})
    end

    test "builds a user channel with custom attributes as a keyword list" do
      assert %UserChannel{channel_name: "custom_name"} = Factory.build(:user_channel, channel_name: "custom_name")
    end

    test "builds a historical user with default attributes" do
      assert %HistoricalUser{} = Factory.build(:historical_user)
    end

    test "builds a historical user with custom attributes as a map" do
      assert %HistoricalUser{nick: "custom_nick"} = Factory.build(:historical_user, %{nick: "custom_nick"})
    end

    test "builds a metric with default attributes" do
      assert %Metric{} = Factory.build(:metric)
    end

    test "builds a metric with custom attributes as a map" do
      assert %Metric{key: :highest_connections, value: 50} =
               Factory.build(:metric, %{key: :highest_connections, value: 50})
    end
  end

  describe "insert/2" do
    test "inserts a user into the database with default attributes" do
      assert %User{} = Factory.insert(:user)
    end

    test "inserts a user into the database with custom attributes as a map" do
      assert %User{nick: "custom_nick"} = Factory.insert(:user, %{nick: "custom_nick"})
    end

    test "inserts a user into the database with custom attributes as a keyword list" do
      assert %User{nick: "custom_nick"} = Factory.insert(:user, nick: "custom_nick")
    end

    test "inserts a channel into the database with default attributes" do
      assert %Channel{} = Factory.insert(:channel)
    end

    test "inserts a channel into the database with custom attributes as a map" do
      assert %Channel{name: "custom_name"} = Factory.insert(:channel, %{name: "custom_name"})
    end

    test "inserts a channel into the database with custom attributes as a keyword list" do
      assert %Channel{name: "custom_name"} = Factory.insert(:channel, name: "custom_name")
    end

    test "inserts a user channel into the database with default attributes" do
      assert %UserChannel{} = Factory.insert(:user_channel)
    end

    test "inserts a user channel into the database with custom attributes as a map" do
      user = Factory.insert(:user)
      channel = Factory.insert(:channel)

      assert %UserChannel{} = user_channel = Factory.insert(:user_channel, %{channel: channel, user: user})
      assert user_channel.user_pid == user.pid
      assert user_channel.user_socket == user.socket
      assert user_channel.user_transport == user.transport
      assert user_channel.channel_name == channel.name
    end

    test "inserts a user channel into the database with custom attributes as a keyword list" do
      user = Factory.insert(:user)
      channel = Factory.insert(:channel)

      assert %UserChannel{} = user_channel = Factory.insert(:user_channel, channel: channel, user: user)
      assert user_channel.user_pid == user.pid
      assert user_channel.user_socket == user.socket
      assert user_channel.user_transport == user.transport
      assert user_channel.channel_name == channel.name
    end

    test "inserts a historical user into the database with default attributes" do
      assert %HistoricalUser{} = Factory.insert(:historical_user)
    end

    test "inserts a historical user into the database with custom attributes as a map" do
      assert %HistoricalUser{} = historical_user = Factory.insert(:historical_user, %{nick: "custom_nick"})
      assert historical_user.nick == "custom_nick"
    end

    test "inserts a metric into the database with default attributes" do
      assert %Metric{} = Factory.insert(:metric)
    end

    test "inserts a metric into the database with custom attributes as a map" do
      assert %Metric{} = metric = Factory.insert(:metric, %{key: :highest_connections, value: 50})
      assert metric.key == :highest_connections
      assert metric.value == 50
    end
  end
end
