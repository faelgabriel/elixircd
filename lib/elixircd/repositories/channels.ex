defmodule ElixIRCd.Repositories.Channels do
  @moduledoc """
  Module for the channels repository.
  """

  alias ElixIRCd.Tables.Channel

  @doc """
  Create a new channel and write it to the database.
  """
  @spec create(map()) :: Channel.t()
  def create(attrs) do
    Channel.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Delete a channel from the database.
  """
  @spec delete(Channel.t()) :: :ok
  def delete(channel) do
    Memento.Query.delete_record(channel)
  end

  @doc """
  Delete a channel by the name from the database.
  """
  @spec delete_by_name(String.t()) :: :ok
  def delete_by_name(name) do
    Memento.Query.delete(Channel, name)
  end

  @doc """
  Update a channel and write it to the database.
  """
  @spec update(Channel.t(), map()) :: Channel.t()
  def update(channel, attrs) do
    Channel.update(channel, attrs)
    |> Memento.Query.write()
  end

  @doc """
  Get all channels.
  """
  @spec get_all() :: [Channel.t()]
  def get_all do
    Memento.Query.select(Channel, [])
  end

  @doc """
  Get a channel by the name.
  """
  @spec get_by_name(String.t()) :: {:ok, Channel.t()} | {:error, :channel_not_found}
  def get_by_name(name) do
    Memento.Query.read(Channel, name)
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
    conditions =
      Enum.map(names, fn name -> {:==, :name, name} end)
      |> Enum.reduce(fn condition, acc -> {:or, condition, acc} end)

    Memento.Query.select(Channel, conditions)
  end

  @doc """
  Count all channels.
  """
  @spec count_all() :: integer()
  def count_all do
    :mnesia.foldl(fn _record, acc -> acc + 1 end, 0, Channel)
  end
end
