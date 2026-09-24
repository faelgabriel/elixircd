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
    delete_by_user_pid_and_channel_name(attrs.user_pid, attrs.channel_name_key)

    ChannelInvite.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Delete all channel invites by the channel name from the database.
  """
  @spec delete_by_channel_name(String.t()) :: :ok
  def delete_by_channel_name(channel_name) do
    channel_name_key = CaseMapping.normalize(channel_name)

    Memento.Query.match(ChannelInvite, {:_, channel_name_key, :_, :_, :_})
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
  Delete a channel invite by the channel name and user pid.
  """
  @spec delete_by_user_pid_and_channel_name(pid(), String.t()) :: :ok
  def delete_by_user_pid_and_channel_name(user_pid, channel_name) do
    channel_name_key = CaseMapping.normalize(channel_name)

    Memento.Query.match(ChannelInvite, {user_pid, channel_name_key, :_, :_, :_})
    |> Enum.each(&Memento.Query.delete_record/1)
  end

  @doc """
  Get all active channel invites for a user.
  """
  @spec get_by_user_pid(pid()) :: [ChannelInvite.t()]
  def get_by_user_pid(user_pid) do
    Memento.Query.match(ChannelInvite, {user_pid, :_, :_, :_, :_})
    |> Enum.sort_by(& &1.created_at, DateTime)
  end

  @doc """
  Get a channel invite by the channel name and user pid.
  """
  @spec get_by_user_pid_and_channel_name(pid(), String.t()) ::
          {:ok, ChannelInvite.t()} | {:error, :channel_invite_not_found}
  def get_by_user_pid_and_channel_name(user_pid, channel_name) do
    channel_name_key = CaseMapping.normalize(channel_name)

    Memento.Query.match(ChannelInvite, {user_pid, channel_name_key, :_, :_, :_})
    |> case do
      [channel_invite | _] -> {:ok, channel_invite}
      [] -> {:error, :channel_invite_not_found}
    end
  end
end
