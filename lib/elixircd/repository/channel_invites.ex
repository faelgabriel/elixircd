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
  Get a channel invite by the channel name and user port.
  """
  @spec get_by_channel_name_and_user_port(String.t(), port()) ::
          {:ok, ChannelInvite.t()} | {:error, :channel_invite_not_found}
  def get_by_channel_name_and_user_port(channel_name, user_port) do
    conditions = [{:==, :channel_name, channel_name}, {:==, :user_port, user_port}]

    Memento.Query.select(ChannelInvite, conditions, limit: 1)
    |> case do
      [channel_invite] -> {:ok, channel_invite}
      [] -> {:error, :channel_invite_not_found}
    end
  end
end
