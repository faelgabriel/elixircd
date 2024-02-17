defmodule ElixIRCd.Factory do
  @moduledoc """
  This module defines the factories for the schemas.
  """

  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  def build(_type, attrs \\ %{})

  @spec build(atom(), keyword()) :: term()
  def build(type, attrs) when is_list(attrs) do
    map_attrs = Enum.into(attrs, %{})
    build(type, map_attrs)
  end

  @spec build(:user, map()) :: User.t()
  def build(:user, attrs) do
    port = Port.open({:spawn, "cat /dev/null"}, [:binary])

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
      identity: Map.get(attrs, :identity, "identity@#{random_string(50)}"),
      created_at: Map.get(attrs, :created_at, DateTime.utc_now())
    }
  end

  @spec build(:channel, map()) :: Channel.t()
  def build(:channel, attrs) do
    %Channel{
      name: Map.get(attrs, :name, "#channel_#{random_string(5)}"),
      topic: Map.get(attrs, :topic, "topic"),
      modes: Map.get(attrs, :modes, []),
      created_at: Map.get(attrs, :created_at, DateTime.utc_now())
    }
  end

  @spec build(:user_channel, map()) :: UserChannel.t()
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

  def insert(_type, attrs \\ %{})

  @spec insert(atom(), keyword()) :: term()
  def insert(type, attrs) when is_list(attrs) do
    map_attrs = Enum.into(attrs, %{})
    insert(type, map_attrs)
  end

  @spec insert(:user, map()) :: User.t()
  def insert(:user, attrs) do
    Memento.transaction!(fn ->
      build(:user, attrs)
      |> Memento.Query.write()
    end)
  end

  @spec insert(:channel, map()) :: Channel.t()
  def insert(:channel, attrs) do
    Memento.transaction!(fn ->
      build(:channel, attrs)
      |> Memento.Query.write()
    end)
  end

  @spec insert(:user_channel, map()) :: UserChannel.t()
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

  @spec random_string(integer()) :: String.t()
  defp random_string(length) do
    Enum.map(1..length, fn _ -> ?a + :rand.uniform(25) end)
    |> List.to_string()
  end
end
