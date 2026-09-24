defmodule ElixIRCd.Repositories.UserChannels do
  @moduledoc """
  Module for the user channels repository.
  """

  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.CaseMapping
  alias Memento.Query.Data

  @doc """
  Create a new user channel and write it to the database.
  """
  @spec create(map()) :: UserChannel.t()
  def create(attrs) do
    UserChannel.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Update a user channel and write it to the database.
  """
  @spec update(UserChannel.t(), map()) :: UserChannel.t()
  def update(user_channel, attrs) do
    delete(user_channel)

    UserChannel.update(user_channel, attrs)
    |> Memento.Query.write()
  end

  @doc """
  Delete a user channel from the database.
  """
  @spec delete(UserChannel.t()) :: :ok
  def delete(user_channel) do
    Memento.Query.delete_record(user_channel)
  end

  @doc """
  Delete a user channel by user pid from the database.
  """
  @spec delete_by_user_pid(pid()) :: :ok
  def delete_by_user_pid(user_pid) do
    Memento.Query.delete(UserChannel, user_pid)
  end

  @doc """
  Get a user channel by the user pid and channel name.
  """
  @spec get_by_user_pid_and_channel_name(pid(), String.t()) ::
          {:ok, UserChannel.t()} | {:error, :user_channel_not_found}
  def get_by_user_pid_and_channel_name(user_pid, channel_name) do
    channel_name_key = CaseMapping.normalize(channel_name)

    Memento.Query.match(UserChannel, {user_pid, channel_name_key, :_, :_})
    |> case do
      [user_channel | _] -> {:ok, user_channel}
      [] -> {:error, :user_channel_not_found}
    end
  end

  @doc """
  Get all user channels by the user pid.
  """
  @spec get_by_user_pid(pid()) :: [UserChannel.t()]
  def get_by_user_pid(user_pid) do
    Memento.Query.match(UserChannel, {user_pid, :_, :_, :_})
  end

  @doc """
  Get all user channels by the user pids.
  """
  @spec get_by_user_pids([pid()]) :: [UserChannel.t()]
  def get_by_user_pids([]), do: []

  def get_by_user_pids(pids) do
    pids
    |> Enum.uniq()
    |> Enum.flat_map(&Memento.Query.match(UserChannel, {&1, :_, :_, :_}))
  end

  @doc """
  Get all user channels by the channel name.
  """
  @spec get_by_channel_name(String.t()) :: [UserChannel.t()]
  def get_by_channel_name(channel_name) do
    channel_name_key = CaseMapping.normalize(channel_name)
    Memento.Query.match(UserChannel, {:_, channel_name_key, :_, :_})
  end

  @doc """
  Get all user channels by the channel names.
  """
  @spec get_by_channel_names([String.t()]) :: [UserChannel.t()]
  def get_by_channel_names([]), do: []

  def get_by_channel_names(channel_names) do
    channel_names
    |> Enum.map(&CaseMapping.normalize/1)
    |> Enum.uniq()
    |> Enum.flat_map(&Memento.Query.match(UserChannel, {:_, &1, :_, :_}))
  end

  @doc """
  Count the number of users in a channel by the channel name.
  """
  @spec count_users_by_channel_name(String.t()) :: integer()
  def count_users_by_channel_name(channel_name) do
    channel_name_key = CaseMapping.normalize(channel_name)

    # Use Mnesia's index for efficient lookup - this is optimal since UserChannel has an index on channel_name_key.
    # This only reads records matching the channel instead of scanning the entire table with foldl or fetching all
    # records into memory.
    :mnesia.index_read(UserChannel, channel_name_key, :channel_name_key)
    |> Enum.count()
  end

  @doc """
  Count the number of users in each channel by the channel names,
  returning a list of tuples with the channel name and the number of users.
  """
  @spec count_users_by_channel_names([String.t()]) :: [{String.t(), integer()}]
  def count_users_by_channel_names([]), do: []

  def count_users_by_channel_names(channel_names) do
    # Optimize by using individual count queries instead of fetching all records
    # This is more efficient for counting operations
    Enum.map(channel_names, fn channel_name ->
      users_count = count_users_by_channel_name(channel_name)
      {channel_name, users_count}
    end)
  end

  @doc """
  Count recent joins to a channel within a time window.
  """
  @spec count_recent_joins_by_channel_name(String.t(), DateTime.t()) :: integer()
  def count_recent_joins_by_channel_name(channel_name, since_time) do
    channel_name_key = CaseMapping.normalize(channel_name)

    :mnesia.index_read(UserChannel, channel_name_key, :channel_name_key)
    |> Enum.count(fn user_channel_record ->
      user_channel = Data.load(user_channel_record)
      DateTime.compare(user_channel.created_at, since_time) != :lt
    end)
  end

  @doc "Returns the users present in any channel without loading membership records."
  @spec all_user_pids() :: MapSet.t(pid())
  def all_user_pids do
    :mnesia.foldl(fn record, acc -> MapSet.put(acc, elem(record, 1)) end, MapSet.new(), UserChannel)
  end
end
