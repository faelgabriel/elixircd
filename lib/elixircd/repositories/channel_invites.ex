defmodule ElixIRCd.Repositories.ChannelInvites do
  @moduledoc """
  Module for the channel invites repository.
  """

  alias ElixIRCd.Tables.ChannelInvite
  alias ElixIRCd.Utils.CaseMapping

  @doc """
  Create a new channel invite and write it to the database.
  """
  @spec create(map()) :: ChannelInvite.t()
  def create(attrs) do
    ChannelInvite.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Delete all channel invites by the channel name from the database.
  """
  @spec delete_by_channel_name(String.t()) :: :ok
  def delete_by_channel_name(channel_name) do
    channel_name_key = CaseMapping.normalize(channel_name)

    Memento.Query.select(ChannelInvite, [{:==, :channel_name_key, channel_name_key}])
    |> Enum.each(&Memento.Query.delete_record/1)
  end

  @doc """
  Delete all user invites by user pid from the database.
  """
  @spec delete_by_user_pid(pid()) :: :ok
  def delete_by_user_pid(user_pid) do
    Memento.Query.delete(ChannelInvite, user_pid)
  end

  @doc """
  Get a channel invite by the channel name and user pid.
  """
  @spec get_by_user_pid_and_channel_name(pid(), String.t()) ::
          {:ok, ChannelInvite.t()} | {:error, :channel_invite_not_found}
  def get_by_user_pid_and_channel_name(user_pid, channel_name) do
    channel_name_key = CaseMapping.normalize(channel_name)
    conditions = [{:==, :user_pid, user_pid}, {:==, :channel_name_key, channel_name_key}]

    Memento.Query.select(ChannelInvite, conditions, limit: 1)
    |> case do
      [channel_invite] -> {:ok, channel_invite}
      [] -> {:error, :channel_invite_not_found}
    end
  end
end
