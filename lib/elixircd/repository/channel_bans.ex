defmodule ElixIRCd.Repository.ChannelBans do
  @moduledoc """
  Module for the channel bans repository.
  """

  alias ElixIRCd.Tables.ChannelBan

  @doc """
  Create a new channel ban and write it to the database.
  """
  @spec create(map()) :: ChannelBan.t()
  def create(attrs) do
    ChannelBan.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Delete a channel ban from the database.
  """
  @spec delete(ChannelBan.t()) :: :ok
  def delete(channel_ban) do
    Memento.Query.delete_record(channel_ban)
  end

  @doc """
  Get all channel bans by the channel name.
  """
  @spec get_by_channel_name(String.t()) :: [ChannelBan.t()]
  def get_by_channel_name(channel_name) do
    Memento.Query.select(ChannelBan, {:==, :channel_name, channel_name})
  end

  @doc """
  Get a channel ban by the channel name and ban mask.
  """
  @spec get_by_channel_name_and_mask(String.t(), String.t()) :: {:ok, ChannelBan.t()} | {:error, String.t()}
  def get_by_channel_name_and_mask(channel_name, mask) do
    conditions = [{:==, :channel_name, channel_name}, {:==, :mask, mask}]

    Memento.Query.select(ChannelBan, conditions, limit: 1)
    |> case do
      [channel_ban] -> {:ok, channel_ban}
      [] -> {:error, "ChannelBan not found"}
    end
  end
end
