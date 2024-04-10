defmodule ElixIRCd.Factory do
  @moduledoc """
  This module defines the factories for the schemas.
  """

  import ElixIRCd.Helper, only: [build_user_mask: 1]

  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Tables.ChannelInvite
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
    port = Port.open({:spawn, "cat /dev/null"}, [:binary])

    registered_at =
      if Map.get(attrs, :registered) == false and Map.get(attrs, :registered_at) == nil,
        do: nil,
        else: Map.get(attrs, :registered_at, DateTime.utc_now())

    %User{
      port: Map.get(attrs, :port, port),
      socket: Map.get(attrs, :socket, port),
      transport: Map.get(attrs, :transport, :ranch_tcp),
      pid: Map.get(attrs, :pid, self()),
      nick: Map.get(attrs, :nick, "Nick_#{random_string(5)}"),
      modes: Map.get(attrs, :modes, []),
      hostname: Map.get(attrs, :hostname, "hostname"),
      username: Map.get(attrs, :username, "username"),
      realname: Map.get(attrs, :realname, "realname"),
      userid: Map.get(attrs, :userid, nil),
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
    port = Port.open({:spawn, "cat /dev/null"}, [:binary])

    %UserChannel{
      user_port: Map.get(attrs, :user_port, port),
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
    %ChannelInvite{
      channel_name: Map.get(attrs, :channel_name, "#channel_#{random_string(5)}"),
      user_mask: Map.get(attrs, :user_mask, "nick!user@host"),
      setter: Map.get(attrs, :setter, "setter"),
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
      |> Map.put(:user_port, user.port)
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
      |> Map.put(:channel_name, channel.name)
      |> Map.put(:user_mask, build_user_mask(user))

    Memento.transaction!(fn ->
      build(:channel_invite, updated_attrs)
      |> Memento.Query.write()
    end)
  end

  @spec random_string(integer()) :: String.t()
  defp random_string(length) do
    Enum.map(1..length, fn _ -> ?a + :rand.uniform(25) end)
    |> List.to_string()
  end
end
