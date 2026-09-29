defmodule ElixIRCd.Repositories.Channels do
  @moduledoc """
  Module for the channels repository.
  """

  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelIdentity
  alias ElixIRCd.Utils.CaseMapping

  @doc """
  Create a new channel and write it to the database.
  """
  @spec create(map()) :: Channel.t()
  def create(attrs) do
    creator = Map.get(attrs, :creator)
    channel = attrs |> Map.delete(:creator) |> Channel.new() |> Memento.Query.write()
    if creator, do: Memento.Query.write(ChannelIdentity.new(channel.name_key, creator))
    channel
  end

  @doc """
  Delete a channel from the database.
  """
  @spec delete(Channel.t()) :: :ok
  def delete(channel) do
    Memento.Query.delete_record(channel)
    Memento.Query.delete(ChannelIdentity, channel.name_key)
  end

  @doc """
  Delete a channel by the name from the database.
  """
  @spec delete_by_name(String.t()) :: :ok
  def delete_by_name(name) do
    name_key = CaseMapping.normalize(name)
    Memento.Query.delete(Channel, name_key)
    Memento.Query.delete(ChannelIdentity, name_key)
  end

  @doc """
  Update a channel and write it to the database.
  """
  @spec update(Channel.t(), map()) :: Channel.t()
  def update(channel, attrs) do
    Channel.update(channel, attrs)
    |> Memento.Query.write()
  end

  @doc "Replaces a channel, including when its normalized name key changes."
  @spec replace(Channel.t(), Channel.t()) :: Channel.t()
  def replace(old, new) do
    identity = Memento.Query.read(ChannelIdentity, old.name_key)
    Memento.Query.delete_record(old)
    Memento.Query.delete(ChannelIdentity, old.name_key)
    written = Memento.Query.write(new)
    if identity, do: Memento.Query.write(%{identity | name_key: new.name_key})
    written
  end

  @doc """
  Get all channels.
  """
  @spec get_all() :: [Channel.t()]
  def get_all do
    Memento.Query.all(Channel)
  end

  @doc """
  Get a channel by the name.
  """
  @spec get_by_name(String.t()) :: {:ok, Channel.t()} | {:error, :channel_not_found}
  def get_by_name(name) do
    name_key = CaseMapping.normalize(name)

    Memento.Query.read(Channel, name_key)
    |> case do
      nil -> {:error, :channel_not_found}
      channel -> {:ok, channel}
    end
  end

  @doc """
  Get all channels by the names.
  """
  @spec get_by_names([String.t()]) :: [Channel.t()]
  def get_by_names([]), do: []

  def get_by_names(names) do
    names
    |> Enum.map(&CaseMapping.normalize/1)
    |> Enum.uniq()
    |> Enum.map(&Memento.Query.read(Channel, &1))
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Count all channels.
  """
  @spec count_all() :: integer()
  def count_all do
    :mnesia.foldl(fn _record, acc -> acc + 1 end, 0, Channel)
  end
end
