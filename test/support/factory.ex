defmodule ElixIRCd.Factory do
  @moduledoc """
  This module defines the factories for the schemas.
  """

  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Tables.ChannelInvite
  alias ElixIRCd.Tables.HistoricalUser
  alias ElixIRCd.Tables.Metric
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

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
    pid = spawn(fn -> :ok end)
    port = Port.open({:spawn, "cat /dev/null"}, [:binary])

    registered_at =
      if Map.get(attrs, :registered) == false and Map.get(attrs, :registered_at) == nil,
        do: nil,
        else: Map.get(attrs, :registered_at, DateTime.utc_now())

    %User{
      pid: Map.get(attrs, :pid, pid),
      socket: Map.get(attrs, :socket, port),
      transport: Map.get(attrs, :transport, :ranch_tcp),
      ip_address: Map.get(attrs, :ip_address, {127, 0, 0, 1}),
      port_connected: Map.get(attrs, :port_connected, 6667),
      nick: Map.get(attrs, :nick, "Nick_#{random_string(5)}"),
      modes: Map.get(attrs, :modes, []),
      hostname: Map.get(attrs, :hostname, "hostname"),
      ident: Map.get(attrs, :ident, "~username"),
      realname: Map.get(attrs, :realname, "realname"),
      registered: Map.get(attrs, :registered, true),
      password: Map.get(attrs, :password, nil),
      away_message: Map.get(attrs, :away_message, nil),
      last_activity: Map.get(attrs, :last_activity, :erlang.system_time(:second)),
      registered_at: registered_at,
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
    pid = spawn(fn -> :ok end)
    port = Port.open({:spawn, "cat /dev/null"}, [:binary])

    %UserChannel{
      user_pid: Map.get(attrs, :user_pid, pid),
      user_socket: Map.get(attrs, :user_socket, port),
      user_transport: Map.get(attrs, :user_transport, :ranch_tcp),
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
    pid = spawn(fn -> :ok end)

    %ChannelInvite{
      user_pid: Map.get(attrs, :user_pid, pid),
      channel_name: Map.get(attrs, :channel_name, "#channel_#{random_string(5)}"),
      setter: Map.get(attrs, :setter, "setter"),
      created_at: Map.get(attrs, :created_at, DateTime.utc_now())
    }
  end

  def build(:historical_user, attrs) do
    %HistoricalUser{
      nick: Map.get(attrs, :nick, "Nick_#{random_string(5)}"),
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
      |> Map.put(:user_socket, user.socket)
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

  @spec random_string(integer()) :: String.t()
  defp random_string(length) do
    Enum.map(1..length, fn _ -> ?a + :rand.uniform(25) end)
    |> List.to_string()
  end
end
