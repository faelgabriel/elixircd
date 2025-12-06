defmodule ElixIRCd.Repositories.ChannelExcepts do
  @moduledoc """
  Module for the channel excepts repository.

  This repository manages ban exceptions (+e mode) for channels.
  """

  alias ElixIRCd.Tables.ChannelExcept

  @doc """
  Create a new channel except and write it to the database.
  """
  @spec create(map()) :: ChannelExcept.t()
  def create(attrs) do
    ChannelExcept.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Delete a channel except from the database.
  """
  @spec delete(ChannelExcept.t()) :: :ok
  def delete(channel_except) do
    Memento.Query.delete_record(channel_except)
  end

  @doc """
  Get all channel excepts by the channel name.
  """
  @spec get_by_channel_name_key(String.t()) :: [ChannelExcept.t()]
  def get_by_channel_name_key(channel_name_key) do
    Memento.Query.select(ChannelExcept, {:==, :channel_name_key, channel_name_key})
  end

  @doc """
  Get a channel except by the channel name and except mask.
  """
  @spec get_by_channel_name_key_and_mask(String.t(), String.t()) ::
          {:ok, ChannelExcept.t()} | {:error, :channel_except_not_found}
  def get_by_channel_name_key_and_mask(channel_name_key, mask) do
    conditions = [{:==, :channel_name_key, channel_name_key}, {:==, :mask, mask}]

    Memento.Query.select(ChannelExcept, conditions, limit: 1)
    |> case do
      [channel_except] -> {:ok, channel_except}
      [] -> {:error, :channel_except_not_found}
    end
  end
end
