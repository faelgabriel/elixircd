defmodule ElixIRCd.Repositories.ChannelInvexes do
  @moduledoc """
  Module for the channel invexes repository.

  This repository manages invite exceptions (+I mode) for channels.
  """

  alias ElixIRCd.Tables.ChannelInvex
  alias ElixIRCd.Repositories.ChannelListTombstones
  alias ElixIRCd.Server.S2S.Publication

  @doc """
  Create a new channel invex and write it to the database.
  """
  @spec create(map()) :: ChannelInvex.t()
  def create(attrs) do
    record = ChannelInvex.new(Map.put(attrs, :stamp, Publication.next_local_stamp()))

    record
    |> Memento.Query.write()
    |> tap(fn record ->
      ChannelListTombstones.delete(record.channel_name_key, "I", record.mask)

      Publication.channel_list_changed(
        record.channel_name_key,
        "I",
        record.mask,
        true,
        record.setter,
        DateTime.to_unix(record.created_at, :millisecond),
        record.stamp
      )
    end)
  end

  @doc """
  Delete a channel invex from the database.
  """
  @spec delete(ChannelInvex.t()) :: :ok
  def delete(channel_invex) do
    result = Memento.Query.delete_record(channel_invex)
    set_ms = System.system_time(:millisecond)
    stamp = Publication.next_local_stamp()

    ChannelListTombstones.put(%{
      channel_name_key: channel_invex.channel_name_key,
      mode: "I",
      mask: channel_invex.mask,
      set_by: channel_invex.setter,
      set_ms: set_ms,
      stamp: stamp
    })

    Publication.channel_list_changed(
      channel_invex.channel_name_key,
      "I",
      channel_invex.mask,
      false,
      channel_invex.setter,
      set_ms,
      stamp
    )

    result
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
    conditions = [{:==, :channel_name_key, channel_name_key}, {:==, :mask, mask}]

    Memento.Query.select(ChannelInvex, conditions, limit: 1)
    |> case do
      [channel_invex] -> {:ok, channel_invex}
      [] -> {:error, :channel_invex_not_found}
    end
  end
end
