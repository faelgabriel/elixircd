defmodule ElixIRCd.Repository.Channels do
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
  Update a channel and write it to the database.
  """
  @spec update(Channel.t(), map()) :: Channel.t()
  def update(channel, attrs) do
    Channel.update(channel, attrs)
    |> Memento.Query.write()
  end

  @doc """
  Get a channel by the name.
  """
  @spec get_by_name(String.t()) :: {:ok, Channel.t()} | {:error, atom()}
  def get_by_name(name) do
    Memento.Query.read(Channel, name)
    |> case do
      nil -> {:error, :channel_not_found}
      channel -> {:ok, channel}
    end
  end
end
