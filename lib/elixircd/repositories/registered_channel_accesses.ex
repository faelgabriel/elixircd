defmodule ElixIRCd.Repositories.RegisteredChannelAccesses do
  @moduledoc """
  Repository for ChanServ registered channel access entries.
  """

  alias ElixIRCd.Tables.RegisteredChannelAccess
  alias ElixIRCd.Utils.CaseMapping
  alias Memento.Query.Data

  @doc """
  Creates or replaces a channel access entry.
  """
  @spec create(map()) :: RegisteredChannelAccess.t()
  def create(attrs) do
    RegisteredChannelAccess.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Lists all access entries for a channel.
  """
  @spec get_by_channel_name(String.t()) :: [RegisteredChannelAccess.t()]
  def get_by_channel_name(channel_name) do
    channel_name_key = CaseMapping.normalize(channel_name)

    :mnesia.index_read(RegisteredChannelAccess, channel_name_key, :channel_name_key)
    |> Enum.map(&Data.load/1)
    |> Enum.sort_by(& &1.account_name)
  end

  @doc """
  Lists all access entries granted to an account across channels.
  """
  @spec get_by_account_name(String.t()) :: [RegisteredChannelAccess.t()]
  def get_by_account_name(account_name) do
    account_name_key = CaseMapping.normalize(account_name)

    :mnesia.index_read(RegisteredChannelAccess, account_name_key, :account_name_key)
    |> Enum.map(&Data.load/1)
    |> Enum.sort_by(& &1.channel_name_key)
  end

  @doc """
  Fetches a specific channel access entry.
  """
  @spec get_by_channel_name_and_account_name(String.t(), String.t()) :: RegisteredChannelAccess.t() | nil
  def get_by_channel_name_and_account_name(channel_name, account_name) do
    channel_name_key = CaseMapping.normalize(channel_name)
    account_name_key = CaseMapping.normalize(account_name)

    Memento.Query.read(RegisteredChannelAccess, {channel_name_key, account_name_key})
  end

  @doc """
  Returns a flags map keyed by account name for the given channel.
  """
  @spec get_flags_map_by_channel_name(String.t()) :: %{optional(String.t()) => String.t()}
  def get_flags_map_by_channel_name(channel_name) do
    get_by_channel_name(channel_name)
    |> Enum.into(%{}, fn entry -> {entry.account_name, entry.flags} end)
  end

  @doc """
  Deletes a specific access entry.
  """
  @spec delete(String.t(), String.t()) :: :ok
  def delete(channel_name, account_name) do
    case get_by_channel_name_and_account_name(channel_name, account_name) do
      nil -> :ok
      entry -> Memento.Query.delete_record(entry)
    end

    :ok
  end

  @doc """
  Deletes all access entries for a channel.
  """
  @spec delete_by_channel_name(String.t()) :: :ok
  def delete_by_channel_name(channel_name) do
    channel_name
    |> get_by_channel_name()
    |> Enum.each(&Memento.Query.delete_record/1)

    :ok
  end
end
