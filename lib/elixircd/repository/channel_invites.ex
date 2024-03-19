defmodule ElixIRCd.Repository.ChannelInvites do
  @moduledoc """
  Module for the channel invites repository.
  """

  alias ElixIRCd.Tables.ChannelInvite

  @doc """
  Create a new channel invite and write it to the database.
  """
  @spec create(map()) :: ChannelInvite.t()
  def create(attrs) do
    ChannelInvite.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Get a channel invite by the channel name and user mask.
  """
  @spec get_by_channel_name_and_user_mask(String.t(), String.t()) :: {:ok, ChannelInvite.t()} | {:error, atom()}
  def get_by_channel_name_and_user_mask(channel_name, user_mask) do
    conditions = [{:==, :channel_name, channel_name}, {:==, :user_mask, user_mask}]

    Memento.Query.select(ChannelInvite, conditions, limit: 1)
    |> case do
      [channel_invite] -> {:ok, channel_invite}
      [] -> {:error, :channel_invite_not_found}
    end
  end
end
