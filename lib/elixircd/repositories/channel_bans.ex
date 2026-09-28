defmodule ElixIRCd.Repositories.ChannelBans do
  @moduledoc """
  Module for the channel bans repository.
  """

  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Utils.Protocol

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

  @doc "Replaces a ban record, including when its channel key changes."
  @spec replace(ChannelBan.t(), ChannelBan.t()) :: ChannelBan.t()
  def replace(old, new) do
    Memento.Query.delete_record(old)
    Memento.Query.write(new)
  end

  @doc """
  Get all channel bans by the channel name.
  """
  @spec get_by_channel_name_key(String.t()) :: [ChannelBan.t()]
  def get_by_channel_name_key(channel_name_key) do
    Memento.Query.match(ChannelBan, {channel_name_key, :_, :_, :_, :_})
  end

  @doc """
  Get a channel ban by the channel name and ban mask.
  """
  @spec get_by_channel_name_key_and_mask(String.t(), String.t()) ::
          {:ok, ChannelBan.t()} | {:error, :channel_ban_not_found}
  def get_by_channel_name_key_and_mask(channel_name_key, mask) do
    mask_key = Protocol.mask_key(mask)

    Memento.Query.match(ChannelBan, {channel_name_key, :_, mask_key, :_, :_})
    |> List.first()
    |> case do
      %ChannelBan{} = channel_ban -> {:ok, channel_ban}
      nil -> {:error, :channel_ban_not_found}
    end
  end
end
