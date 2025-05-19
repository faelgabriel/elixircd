defmodule ElixIRCd.Factory do
  @moduledoc """
  This module defines the factories for the schemas.
  """

  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Tables.ChannelInvite
  alias ElixIRCd.Tables.HistoricalUser
  alias ElixIRCd.Tables.Metric
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.CaseMapping

  @doc """
  Builds a struct with the given attributes.
  """
  @spec build(atom(), map()) :: term()
  def build(_type, attrs \\ %{})

  def build(type, attrs) when is_list(attrs) do
    map_attrs = Enum.into(attrs, %{})
    build(type, map_attrs)
  end

  def build(:user, attrs) do
    nick = Map.get(attrs, :nick, "Nick_#{random_string(5)}")
    nick_key = if nick, do: CaseMapping.normalize(nick), else: nil

    registered_at =
      if Map.get(attrs, :registered) == false and Map.get(attrs, :registered_at) == nil,
        do: nil,
        else: Map.get(attrs, :registered_at, DateTime.utc_now())

    %User{
      pid: Map.get(attrs, :pid, new_pid()),
      transport: Map.get(attrs, :transport, :tcp),
      ip_address: Map.get(attrs, :ip_address, {127, 0, 0, 1}),
      port_connected: Map.get(attrs, :port_connected, 6667),
      nick_key: nick_key,
      nick: nick,
      modes: Map.get(attrs, :modes, []),
      hostname: Map.get(attrs, :hostname, "hostname"),
      ident: Map.get(attrs, :ident, "~username"),
      realname: Map.get(attrs, :realname, "realname"),
      registered: Map.get(attrs, :registered, true),
      password: Map.get(attrs, :password, nil),
      away_message: Map.get(attrs, :away_message, nil),
      last_activity: Map.get(attrs, :last_activity, :erlang.system_time(:second)),
      registered_at: registered_at,
      identified_as: Map.get(attrs, :identified_as, nil),
      created_at: Map.get(attrs, :created_at, DateTime.utc_now())
    }
  end

  def build(:channel, attrs) do
    %Channel{
      name: Map.get(attrs, :name, "#channel_#{random_string(5)}"),
      topic: Map.get(attrs, :topic, build(:channel_topic)),
      modes: Map.get(attrs, :modes, []),
      created_at: Map.get(attrs, :created_at, DateTime.utc_now())
    }
  end

  def build(:channel_topic, attrs) do
    %Channel.Topic{
      text: Map.get(attrs, :text, "topic"),
      setter: Map.get(attrs, :setter, "setter"),
      set_at: Map.get(attrs, :set_at, DateTime.utc_now())
    }
  end

  def build(:user_channel, attrs) do
    %UserChannel{
      user_pid: Map.get(attrs, :user_pid, new_pid()),
      user_transport: Map.get(attrs, :user_transport, :tcp),
      channel_name: Map.get(attrs, :channel_name, "#channel_#{random_string(5)}"),
      modes: Map.get(attrs, :modes, []),
      created_at: Map.get(attrs, :created_at, DateTime.utc_now())
    }
  end

  def build(:channel_ban, attrs) do
    %ChannelBan{
      channel_name: Map.get(attrs, :channel_name, "#channel_#{random_string(5)}"),
      mask: Map.get(attrs, :mask, "nick!user@host"),
      setter: Map.get(attrs, :setter, "setter"),
      created_at: Map.get(attrs, :created_at, DateTime.utc_now())
    }
  end

  def build(:channel_invite, attrs) do
    %ChannelInvite{
      user_pid: Map.get(attrs, :user_pid, new_pid()),
      channel_name: Map.get(attrs, :channel_name, "#channel_#{random_string(5)}"),
      setter: Map.get(attrs, :setter, "setter"),
      created_at: Map.get(attrs, :created_at, DateTime.utc_now())
    }
  end

  def build(:historical_user, attrs) do
    nick = Map.get(attrs, :nick, "Nick_#{random_string(5)}")
    nick_key = if nick, do: CaseMapping.normalize(nick), else: nil

    %HistoricalUser{
      nick_key: nick_key,
      nick: nick,
      hostname: Map.get(attrs, :hostname, "hostname"),
      ident: Map.get(attrs, :ident, "ident"),
      realname: Map.get(attrs, :realname, "realname"),
      created_at: Map.get(attrs, :created_at, DateTime.utc_now())
    }
  end

  def build(:metric, attrs) do
    %Metric{
      key: Map.get(attrs, :key, :total_connections),
      value: Map.get(attrs, :value, 10)
    }
  end

  def build(:registered_channel, attrs) do
    created_at = Map.get(attrs, :created_at, DateTime.utc_now())
    last_used_at = Map.get(attrs, :last_used_at, created_at)

    %RegisteredChannel{
      name: Map.get(attrs, :name, "#channel_#{random_string(5)}"),
      founder: Map.get(attrs, :founder, "Nick_#{random_string(5)}"),
      password_hash: Map.get(attrs, :password_hash, "hash"),
      registered_by: Map.get(attrs, :registered_by, "user@host"),
      settings: Map.get(attrs, :settings, RegisteredChannel.Settings.new()),
      topic: Map.get(attrs, :topic, nil),
      successor: Map.get(attrs, :successor, nil),
      created_at: created_at,
      last_used_at: last_used_at
    }
  end

  def build(:registered_nick, attrs) do
    %RegisteredNick{
      nickname: Map.get(attrs, :nickname, "nick_#{random_string(5)}"),
      password_hash: Map.get(attrs, :password_hash, "hash"),
      email: Map.get(attrs, :email, "email@example.com"),
      registered_by: Map.get(attrs, :registered_by, "user@host"),
      verify_code: Map.get(attrs, :verify_code, nil),
      verified_at: Map.get(attrs, :verified_at, DateTime.utc_now()),
      last_seen_at: Map.get(attrs, :last_seen_at, DateTime.utc_now()),
      reserved_until: Map.get(attrs, :reserved_until, nil),
      settings: Map.get(attrs, :settings, RegisteredNick.Settings.new()),
      created_at: Map.get(attrs, :created_at, DateTime.utc_now())
    }
  end

  @doc """
  Inserts a new struct with the given attributes into the database.
  """
  @spec insert(atom(), map()) :: term()
  def insert(_type, attrs \\ %{})

  def insert(type, attrs) when is_list(attrs) do
    map_attrs = Enum.into(attrs, %{})
    insert(type, map_attrs)
  end

  def insert(:user, attrs) do
    Memento.transaction!(fn ->
      build(:user, attrs)
      |> Memento.Query.write()
    end)
  end

  def insert(:channel, attrs) do
    Memento.transaction!(fn ->
      build(:channel, attrs)
      |> Memento.Query.write()
    end)
  end

  def insert(:user_channel, attrs) do
    user =
      case Map.get(attrs, :user) do
        nil -> insert(:user)
        user -> user
      end

    channel =
      case Map.get(attrs, :channel) do
        nil -> insert(:channel)
        channel -> channel
      end

    updated_attrs =
      attrs
      |> Map.put(:user_pid, user.pid)
      |> Map.put(:user_transport, user.transport)
      |> Map.put(:channel_name, channel.name)

    Memento.transaction!(fn ->
      build(:user_channel, updated_attrs)
      |> Memento.Query.write()
    end)
  end

  def insert(:channel_ban, attrs) do
    channel =
      case Map.get(attrs, :channel) do
        nil -> insert(:channel)
        channel -> channel
      end

    updated_attrs =
      attrs
      |> Map.put(:channel_name, channel.name)

    Memento.transaction!(fn ->
      build(:channel_ban, updated_attrs)
      |> Memento.Query.write()
    end)
  end

  def insert(:channel_invite, attrs) do
    channel =
      case Map.get(attrs, :channel) do
        nil -> insert(:channel)
        channel -> channel
      end

    user =
      case Map.get(attrs, :user) do
        nil -> insert(:user)
        user -> user
      end

    updated_attrs =
      attrs
      |> Map.put(:user_pid, user.pid)
      |> Map.put(:channel_name, channel.name)

    Memento.transaction!(fn ->
      build(:channel_invite, updated_attrs)
      |> Memento.Query.write()
    end)
  end

  def insert(:historical_user, attrs) do
    Memento.transaction!(fn ->
      build(:historical_user, attrs)
      |> Memento.Query.write()
    end)
  end

  def insert(:metric, attrs) do
    Memento.transaction!(fn ->
      build(:metric, attrs)
      |> Memento.Query.write()
    end)
  end

  def insert(:registered_channel, attrs) do
    Memento.transaction!(fn ->
      build(:registered_channel, attrs)
      |> Memento.Query.write()
    end)
  end

  def insert(:registered_nick, attrs) do
    Memento.transaction!(fn ->
      build(:registered_nick, attrs)
      |> Memento.Query.write()
    end)
  end

  @spec random_string(integer()) :: String.t()
  defp random_string(length) do
    Enum.map(1..length, fn _ -> ?a + :rand.uniform(25) end)
    |> List.to_string()
  end

  @spec new_pid() :: pid()
  defp new_pid, do: spawn(fn -> :ok end)
end
