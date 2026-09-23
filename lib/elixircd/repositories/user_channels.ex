defmodule ElixIRCd.Repositories.UserChannels do
  @moduledoc """
  Module for the user channels repository.
  """

  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.S2S.Publication
  alias ElixIRCd.Utils.CaseMapping
  alias Memento.Query.Data

  @doc """
  Create a new user channel and write it to the database.
  """
  @spec create(map()) :: UserChannel.t()
  @spec create(map(), term()) :: UserChannel.t()
  def create(attrs, cause \\ nil) do
    attrs = put_uid(attrs)
    attrs = Map.put_new(attrs, :join_id, next_join_id(attrs[:uid]))

    UserChannel.new(attrs)
    |> Memento.Query.write()
    |> tap(fn record ->
      _ = Users.bump_membership_revision(record.uid)
      Publication.memberships_changed(record.uid, normalize_cause(cause, record))
    end)
  end

  @doc """
  Update a user channel and write it to the database.
  """
  @spec update(UserChannel.t(), map()) :: UserChannel.t()
  @spec update(UserChannel.t(), map(), term()) :: UserChannel.t()
  def update(user_channel, attrs, cause \\ nil) do
    Memento.Query.delete_record(user_channel)

    user_channel
    |> UserChannel.update(attrs)
    |> Memento.Query.write()
    |> tap(fn record ->
      _ = Users.bump_membership_revision(record.uid)
      Publication.memberships_changed(record.uid, normalize_cause(cause, record))
    end)
  end

  @doc """
  Delete a user channel from the database.
  """
  @spec delete(UserChannel.t()) :: :ok
  @spec delete(UserChannel.t(), term()) :: :ok
  def delete(user_channel, cause \\ nil) do
    result = Memento.Query.delete_record(user_channel)
    _ = Users.bump_membership_revision(user_channel.uid)
    Publication.memberships_changed(user_channel.uid, normalize_cause(cause, user_channel))
    result
  end

  @doc """
  Delete a user channel by user pid from the database.
  """
  @spec delete_by_user_pid(pid()) :: :ok
  @spec delete_by_user_pid(pid(), term()) :: :ok
  def delete_by_user_pid(user_pid, cause \\ nil) do
    if is_pid(user_pid) do
      records = get_by_user_pid(user_pid)
      Enum.each(records, &Memento.Query.delete_record/1)

      records
      |> Enum.map(& &1.uid)
      |> Enum.uniq()
      |> Enum.each(fn uid ->
        _ = Users.bump_membership_revision(uid)
        Publication.memberships_changed(uid, cause)
      end)
    end

    :ok
  end

  @doc """
  Get a user channel by the user pid and channel name.
  """
  @spec get_by_user_pid_and_channel_name(pid(), String.t()) ::
          {:ok, UserChannel.t()} | {:error, :user_channel_not_found}
  def get_by_user_pid_and_channel_name(user_pid, channel_name) do
    if is_pid(user_pid) do
      channel_name_key = CaseMapping.normalize(channel_name)
      conditions = [{:==, :user_pid, user_pid}, {:==, :channel_name_key, channel_name_key}]

      Memento.Query.select(UserChannel, conditions, limit: 1)
      |> case do
        [user_channel] -> {:ok, user_channel}
        [] -> {:error, :user_channel_not_found}
      end
    else
      {:error, :invalid_local_pid}
    end
  end

  @doc """
  Get all user channels by the user pid.
  """
  @spec get_by_user_pid(pid()) :: [UserChannel.t()]
  def get_by_user_pid(user_pid) do
    if is_pid(user_pid), do: Memento.Query.select(UserChannel, {:==, :user_pid, user_pid}), else: []
  end

  @doc """
  Get all user channels by the user pids.
  """
  @spec get_by_user_pids([pid()]) :: [UserChannel.t()]
  def get_by_user_pids([]), do: []

  def get_by_user_pids(pids) do
    pids = Enum.filter(pids, &is_pid/1)

    if pids == [] do
      []
    else
      conditions =
        Enum.map(pids, fn pid -> {:==, :user_pid, pid} end)
        |> Enum.reduce(fn condition, acc -> {:or, condition, acc} end)

      Memento.Query.select(UserChannel, conditions)
    end
  end

  @doc "Returns membership records by stable UID."
  @spec get_by_uid(String.t()) :: [UserChannel.t()]
  def get_by_uid(uid) when is_binary(uid), do: Memento.Query.select(UserChannel, {:==, :uid, uid})
  def get_by_uid(_uid), do: []

  @doc "Returns membership records for stable UIDs."
  @spec get_by_uids([String.t()]) :: [UserChannel.t()]
  def get_by_uids(uids) do
    uids = Enum.filter(uids, &is_binary/1)

    case uids do
      [] ->
        []

      _ ->
        conditions =
          Enum.map(uids, fn uid -> {:==, :uid, uid} end)
          |> Enum.reduce(fn condition, acc -> {:or, condition, acc} end)

        Memento.Query.select(UserChannel, conditions)
    end
  end

  @doc """
  Get all user channels by the channel name.
  """
  @spec get_by_channel_name(String.t()) :: [UserChannel.t()]
  def get_by_channel_name(channel_name) do
    channel_name_key = CaseMapping.normalize(channel_name)
    Memento.Query.select(UserChannel, {:==, :channel_name_key, channel_name_key})
  end

  @doc """
  Get all user channels by the channel names.
  """
  @spec get_by_channel_names([String.t()]) :: [UserChannel.t()]
  def get_by_channel_names([]), do: []

  def get_by_channel_names(channel_names) do
    conditions =
      Enum.map(channel_names, fn channel_name ->
        channel_name_key = CaseMapping.normalize(channel_name)
        {:==, :channel_name_key, channel_name_key}
      end)
      |> Enum.reduce(fn condition, acc -> {:or, condition, acc} end)

    Memento.Query.select(UserChannel, conditions)
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

  defp put_uid(%{uid: uid} = attrs) when is_binary(uid), do: attrs

  defp put_uid(%{user_pid: pid} = attrs) when is_pid(pid) do
    case Users.uid_for_pid(pid) do
      {:ok, uid} -> Map.put(attrs, :uid, uid)
      _ -> attrs
    end
  end

  defp put_uid(attrs), do: attrs

  defp normalize_cause(
         %{"action" => action, "join_id" => nil} = cause,
         %UserChannel{join_id: join_id}
       )
       when action in ~w(join part kick) and is_integer(join_id) and join_id > 0 do
    Map.put(cause, "join_id", join_id)
  end

  defp normalize_cause(cause, _user_channel), do: cause

  defp next_join_id(uid) when is_binary(uid) do
    revision =
      case Users.get_by_uid(uid) do
        {:ok, user} -> user.membership_rev || 0
        _ -> 0
      end

    current_max =
      get_by_uid(uid)
      |> Enum.map(&(&1.join_id || 0))
      |> Enum.max(fn -> 0 end)

    next = max(revision, current_max) + 1

    if next <= ElixIRCd.Server.S2S.Identity.max_uint(), do: next, else: raise(ArgumentError, "join_id exhausted")
  end

  defp next_join_id(_uid), do: 1
end
