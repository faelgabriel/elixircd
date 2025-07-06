defmodule ElixIRCd.FactoryTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Factory
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Tables.ChannelInvite
  alias ElixIRCd.Tables.HistoricalUser
  alias ElixIRCd.Tables.Job
  alias ElixIRCd.Tables.Metric
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserAccept
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Tables.UserSilence

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

    test "builds a user accept with default attributes" do
      assert %UserAccept{} = Factory.build(:user_accept)
    end

    test "builds a user accept with custom attributes as a map" do
      assert %UserAccept{} = user_accept = Factory.build(:user_accept, %{user_pid: spawn(fn -> :ok end)})
      assert is_pid(user_accept.user_pid)
    end

    test "builds a user accept with custom attributes as a keyword list" do
      user_pid = spawn(fn -> :ok end)
      assert %UserAccept{user_pid: ^user_pid} = Factory.build(:user_accept, user_pid: user_pid)
    end

    test "builds a user silence with default attributes" do
      assert %UserSilence{} = Factory.build(:user_silence)
    end

    test "builds a user silence with custom attributes as a map" do
      assert %UserSilence{mask: "custom!user@host"} = Factory.build(:user_silence, %{mask: "custom!user@host"})
    end

    test "builds a user silence with custom attributes as a keyword list" do
      assert %UserSilence{mask: "custom!user@host"} = Factory.build(:user_silence, mask: "custom!user@host")
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

    test "builds a channel topic with default attributes" do
      assert %Channel.Topic{} = Factory.build(:channel_topic)
    end

    test "builds a channel topic with custom attributes as a map" do
      assert %Channel.Topic{text: "custom topic"} = Factory.build(:channel_topic, %{text: "custom topic"})
    end

    test "builds a channel topic with custom attributes as a keyword list" do
      assert %Channel.Topic{text: "custom topic"} = Factory.build(:channel_topic, text: "custom topic")
    end

    test "builds a user channel with default attributes" do
      assert %UserChannel{} = Factory.build(:user_channel)
    end

    test "builds a user channel with custom attributes as a map" do
      assert %UserChannel{channel_name_key: "custom_name"} =
               Factory.build(:user_channel, %{channel_name_key: "custom_name"})
    end

    test "builds a user channel with custom attributes as a keyword list" do
      assert %UserChannel{channel_name_key: "custom_name"} =
               Factory.build(:user_channel, channel_name_key: "custom_name")
    end

    test "builds a channel ban with default attributes" do
      assert %ChannelBan{} = Factory.build(:channel_ban)
    end

    test "builds a channel ban with custom attributes as a map" do
      assert %ChannelBan{mask: "custom!user@host"} = Factory.build(:channel_ban, %{mask: "custom!user@host"})
    end

    test "builds a channel ban with custom attributes as a keyword list" do
      assert %ChannelBan{mask: "custom!user@host"} = Factory.build(:channel_ban, mask: "custom!user@host")
    end

    test "builds a channel invite with default attributes" do
      assert %ChannelInvite{} = Factory.build(:channel_invite)
    end

    test "builds a channel invite with custom attributes as a map" do
      assert %ChannelInvite{setter: "custom_setter"} = Factory.build(:channel_invite, %{setter: "custom_setter"})
    end

    test "builds a channel invite with custom attributes as a keyword list" do
      assert %ChannelInvite{setter: "custom_setter"} = Factory.build(:channel_invite, setter: "custom_setter")
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

    test "builds a registered nick with default attributes" do
      assert %RegisteredNick{} = Factory.build(:registered_nick)
    end

    test "builds a registered nick with custom attributes as a map" do
      assert %RegisteredNick{nickname: "custom_nick"} = Factory.build(:registered_nick, %{nickname: "custom_nick"})
    end

    test "builds a registered nick with custom attributes as a keyword list" do
      assert %RegisteredNick{nickname: "custom_nick"} = Factory.build(:registered_nick, nickname: "custom_nick")
    end

    test "builds a registered channel with default attributes" do
      assert %RegisteredChannel{} = Factory.build(:registered_channel)
    end

    test "builds a registered channel with custom attributes as a map" do
      assert %RegisteredChannel{name: "#custom_channel"} =
               Factory.build(:registered_channel, %{name: "#custom_channel"})
    end

    test "builds a registered channel with custom attributes as a keyword list" do
      assert %RegisteredChannel{name: "#custom_channel"} = Factory.build(:registered_channel, name: "#custom_channel")
    end

    test "builds a job with default attributes" do
      assert %Job{} = Factory.build(:job)
    end

    test "builds a job with custom attributes as a map" do
      assert %Job{status: :processing} = Factory.build(:job, %{status: :processing})
    end

    test "builds a job with custom attributes as a keyword list" do
      assert %Job{status: :processing} = Factory.build(:job, status: :processing)
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

    test "inserts a user accept into the database with default attributes" do
      assert %UserAccept{} = Factory.insert(:user_accept)
    end

    test "inserts a user accept into the database with custom attributes as a map" do
      user = Factory.insert(:user)
      accepted_user = Factory.insert(:user)

      assert %UserAccept{} = user_accept = Factory.insert(:user_accept, %{user: user, accepted_user: accepted_user})
      assert user_accept.user_pid == user.pid
      assert user_accept.accepted_user_pid == accepted_user.pid
    end

    test "inserts a user accept into the database with custom attributes as a keyword list" do
      user = Factory.insert(:user)
      accepted_user = Factory.insert(:user)

      assert %UserAccept{} = user_accept = Factory.insert(:user_accept, user: user, accepted_user: accepted_user)
      assert user_accept.user_pid == user.pid
      assert user_accept.accepted_user_pid == accepted_user.pid
    end

    test "inserts a user silence into the database with default attributes" do
      assert %UserSilence{} = Factory.insert(:user_silence)
    end

    test "inserts a user silence into the database with custom attributes as a map" do
      user = Factory.insert(:user)

      assert %UserSilence{} = user_silence = Factory.insert(:user_silence, %{user: user, mask: "test!user@host"})
      assert user_silence.user_pid == user.pid
      assert user_silence.mask == "test!user@host"
    end

    test "inserts a user silence into the database with custom attributes as a keyword list" do
      user = Factory.insert(:user)

      assert %UserSilence{} = user_silence = Factory.insert(:user_silence, user: user, mask: "test!user@host")
      assert user_silence.user_pid == user.pid
      assert user_silence.mask == "test!user@host"
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
      assert user_channel.user_transport == user.transport
      assert user_channel.channel_name_key == channel.name_key
    end

    test "inserts a user channel into the database with custom attributes as a keyword list" do
      user = Factory.insert(:user)
      channel = Factory.insert(:channel)

      assert %UserChannel{} = user_channel = Factory.insert(:user_channel, channel: channel, user: user)
      assert user_channel.user_pid == user.pid
      assert user_channel.user_transport == user.transport
      assert user_channel.channel_name_key == channel.name_key
    end

    test "inserts a channel ban into the database with default attributes" do
      assert %ChannelBan{} = Factory.insert(:channel_ban)
    end

    test "inserts a channel ban into the database with custom attributes as a map" do
      channel = Factory.insert(:channel)

      assert %ChannelBan{} = channel_ban = Factory.insert(:channel_ban, %{channel: channel, mask: "test!user@host"})
      assert channel_ban.channel_name_key == channel.name_key
      assert channel_ban.mask == "test!user@host"
    end

    test "inserts a channel ban into the database with custom attributes as a keyword list" do
      channel = Factory.insert(:channel)

      assert %ChannelBan{} = channel_ban = Factory.insert(:channel_ban, channel: channel, mask: "test!user@host")
      assert channel_ban.channel_name_key == channel.name_key
      assert channel_ban.mask == "test!user@host"
    end

    test "inserts a channel invite into the database with default attributes" do
      assert %ChannelInvite{} = Factory.insert(:channel_invite)
    end

    test "inserts a channel invite into the database with custom attributes as a map" do
      user = Factory.insert(:user)
      channel = Factory.insert(:channel)

      assert %ChannelInvite{} =
               channel_invite = Factory.insert(:channel_invite, %{user: user, channel: channel, setter: "test_user"})

      assert channel_invite.user_pid == user.pid
      assert channel_invite.channel_name_key == channel.name_key
      assert channel_invite.setter == "test_user"
    end

    test "inserts a channel invite into the database with custom attributes as a keyword list" do
      user = Factory.insert(:user)
      channel = Factory.insert(:channel)

      assert %ChannelInvite{} =
               channel_invite = Factory.insert(:channel_invite, user: user, channel: channel, setter: "test_user")

      assert channel_invite.user_pid == user.pid
      assert channel_invite.channel_name_key == channel.name_key
      assert channel_invite.setter == "test_user"
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

    test "inserts a registered nick into the database with default attributes" do
      assert %RegisteredNick{} = Factory.insert(:registered_nick)
    end

    test "inserts a registered nick into the database with custom attributes as a map" do
      assert %RegisteredNick{} = nick = Factory.insert(:registered_nick, %{nickname: "custom_nick"})
      assert nick.nickname == "custom_nick"
    end

    test "inserts a registered nick into the database with custom attributes as a keyword list" do
      assert %RegisteredNick{} = nick = Factory.insert(:registered_nick, nickname: "custom_nick")
      assert nick.nickname == "custom_nick"
    end

    test "inserts a registered channel into the database with default attributes" do
      assert %RegisteredChannel{} = Factory.insert(:registered_channel)
    end

    test "inserts a registered channel into the database with custom attributes as a map" do
      assert %RegisteredChannel{} = channel = Factory.insert(:registered_channel, %{name: "#custom_channel"})
      assert channel.name == "#custom_channel"
    end

    test "inserts a registered channel into the database with custom attributes as a keyword list" do
      assert %RegisteredChannel{} = channel = Factory.insert(:registered_channel, name: "#custom_channel")
      assert channel.name == "#custom_channel"
    end
  end
end
