defmodule ElixIRCd.Repositories.ChannelBans do
  @moduledoc """
  Module for the channel bans repository.
  """

  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Repositories.ChannelListTombstones
  alias ElixIRCd.Server.S2S.Publication

  @doc """
  Create a new channel ban and write it to the database.
  """
  @spec create(map()) :: ChannelBan.t()
  def create(attrs) do
    record = ChannelBan.new(Map.put(attrs, :stamp, Publication.next_local_stamp()))

    record
    |> Memento.Query.write()
    |> tap(fn record ->
      ChannelListTombstones.delete(record.channel_name_key, "b", record.mask)

      Publication.channel_list_changed(
        record.channel_name_key,
        "b",
        record.mask,
        true,
        record.setter,
        DateTime.to_unix(record.created_at, :millisecond),
        record.stamp
      )
    end)
  end

  @doc """
  Delete a channel ban from the database.
  """
  @spec delete(ChannelBan.t()) :: :ok
  def delete(channel_ban) do
    result = Memento.Query.delete_record(channel_ban)
    set_ms = System.system_time(:millisecond)
    stamp = Publication.next_local_stamp()

    ChannelListTombstones.put(%{
      channel_name_key: channel_ban.channel_name_key,
      mode: "b",
      mask: channel_ban.mask,
      set_by: channel_ban.setter,
      set_ms: set_ms,
      stamp: stamp
    })

    Publication.channel_list_changed(
      channel_ban.channel_name_key,
      "b",
      channel_ban.mask,
      false,
      channel_ban.setter,
      set_ms,
      stamp
    )

    result
  end

  @doc """
  Get all channel bans by the channel name.
  """
  @spec get_by_channel_name_key(String.t()) :: [ChannelBan.t()]
  def get_by_channel_name_key(channel_name_key) do
    Memento.Query.select(ChannelBan, {:==, :channel_name_key, channel_name_key})
  end

  @doc """
  Get a channel ban by the channel name and ban mask.
  """
  @spec get_by_channel_name_key_and_mask(String.t(), String.t()) ::
          {:ok, ChannelBan.t()} | {:error, :channel_ban_not_found}
  def get_by_channel_name_key_and_mask(channel_name_key, mask) do
    conditions = [{:==, :channel_name_key, channel_name_key}, {:==, :mask, mask}]

    Memento.Query.select(ChannelBan, conditions, limit: 1)
    |> case do
      [channel_ban] -> {:ok, channel_ban}
      [] -> {:error, :channel_ban_not_found}
    end
  end
end
