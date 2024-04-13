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
  Delete a user invite by user port from the database.
  """
  @spec delete_by_user_port(port()) :: :ok
  def delete_by_user_port(user_port) do
    Memento.Query.delete(ChannelInvite, user_port)
  end

  @doc """
  Get a channel invite by the channel name and user port.
  """
  @spec get_by_user_port_and_channel_name(port(), String.t()) ::
          {:ok, ChannelInvite.t()} | {:error, :channel_invite_not_found}
  def get_by_user_port_and_channel_name(user_port, channel_name) do
    conditions = [{:==, :user_port, user_port}, {:==, :channel_name, channel_name}]

    Memento.Query.select(ChannelInvite, conditions, limit: 1)
    |> case do
      [channel_invite] -> {:ok, channel_invite}
      [] -> {:error, :channel_invite_not_found}
    end
  end
end
