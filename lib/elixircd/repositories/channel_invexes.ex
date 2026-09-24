defmodule ElixIRCd.Repositories.ChannelInvexes do
  @moduledoc """
  Module for the channel invexes repository.

  This repository manages invite exceptions (+I mode) for channels.
  """

  alias ElixIRCd.Tables.ChannelInvex
  alias ElixIRCd.Utils.CaseMapping

  @doc """
  Create a new channel invex and write it to the database.
  """
  @spec create(map()) :: ChannelInvex.t()
  def create(attrs) do
    ChannelInvex.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Delete a channel invex from the database.
  """
  @spec delete(ChannelInvex.t()) :: :ok
  def delete(channel_invex) do
    Memento.Query.delete_record(channel_invex)
  end

  @doc """
  Get all channel invexes by the channel name.
  """
  @spec get_by_channel_name_key(String.t()) :: [ChannelInvex.t()]
  def get_by_channel_name_key(channel_name_key) do
    Memento.Query.select(ChannelInvex, {:==, :channel_name_key, channel_name_key})
  end

  @doc """
  Get a channel invex by the channel name and invex mask.
  """
  @spec get_by_channel_name_key_and_mask(String.t(), String.t()) ::
          {:ok, ChannelInvex.t()} | {:error, :channel_invex_not_found}
  def get_by_channel_name_key_and_mask(channel_name_key, mask) do
    mask_key = CaseMapping.normalize(mask)

    get_by_channel_name_key(channel_name_key)
    |> Enum.find(&(CaseMapping.normalize(&1.mask) == mask_key))
    |> case do
      %ChannelInvex{} = channel_invex -> {:ok, channel_invex}
      nil -> {:error, :channel_invex_not_found}
    end
  end
end
