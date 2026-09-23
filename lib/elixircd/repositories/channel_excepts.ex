defmodule ElixIRCd.Repositories.ChannelExcepts do
  @moduledoc """
  Module for the channel excepts repository.

  This repository manages ban exceptions (+e mode) for channels.
  """

  alias ElixIRCd.Tables.ChannelExcept
  alias ElixIRCd.Repositories.ChannelListTombstones
  alias ElixIRCd.Server.S2S.Publication

  @doc """
  Create a new channel except and write it to the database.
  """
  @spec create(map()) :: ChannelExcept.t()
  def create(attrs) do
    record = ChannelExcept.new(Map.put(attrs, :stamp, Publication.next_local_stamp()))

    record
    |> Memento.Query.write()
    |> tap(fn record ->
      ChannelListTombstones.delete(record.channel_name_key, "e", record.mask)

      Publication.channel_list_changed(
        record.channel_name_key,
        "e",
        record.mask,
        true,
        record.setter,
        DateTime.to_unix(record.created_at, :millisecond),
        record.stamp
      )
    end)
  end

  @doc """
  Delete a channel except from the database.
  """
  @spec delete(ChannelExcept.t()) :: :ok
  def delete(channel_except) do
    result = Memento.Query.delete_record(channel_except)
    set_ms = System.system_time(:millisecond)
    stamp = Publication.next_local_stamp()

    ChannelListTombstones.put(%{
      channel_name_key: channel_except.channel_name_key,
      mode: "e",
      mask: channel_except.mask,
      set_by: channel_except.setter,
      set_ms: set_ms,
      stamp: stamp
    })

    Publication.channel_list_changed(
      channel_except.channel_name_key,
      "e",
      channel_except.mask,
      false,
      channel_except.setter,
      set_ms,
      stamp
    )

    result
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
