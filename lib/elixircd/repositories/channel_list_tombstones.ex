defmodule ElixIRCd.Repositories.ChannelListTombstones do
  @moduledoc "Durable ENP/1 removal stamps for channel list slots."

  alias ElixIRCd.Tables.ChannelListTombstone

  @doc "Writes one durable channel-list removal stamp."
  @spec put(map()) :: ChannelListTombstone.t()
  def put(attrs), do: attrs |> ChannelListTombstone.new() |> Memento.Query.write()

  @doc "Deletes one channel-list removal stamp when it exists."
  @spec delete(String.t(), String.t(), String.t()) :: :ok | term()
  def delete(channel_name_key, mode, mask) do
    case Memento.Query.read(ChannelListTombstone, {channel_name_key, mode, mask}) do
      nil -> :ok
      record -> Memento.Query.delete_record(record)
    end
  end

  @doc "Returns all removal stamps for one canonical channel name."
  @spec get_by_channel_name_key(String.t()) :: [ChannelListTombstone.t()]
  def get_by_channel_name_key(channel_name_key) do
    Memento.Query.select(ChannelListTombstone, {:==, :channel_name_key, channel_name_key})
  end

  @doc "Returns one channel-list removal stamp by its composite key."
  @spec get(String.t(), String.t(), String.t()) :: ChannelListTombstone.t() | nil
  def get(channel_name_key, mode, mask),
    do: Memento.Query.read(ChannelListTombstone, {channel_name_key, mode, mask})
end
