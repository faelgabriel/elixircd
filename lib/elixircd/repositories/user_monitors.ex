defmodule ElixIRCd.Repositories.UserMonitors do
  @moduledoc """
  Repository for managing user monitor lists.
  """

  alias ElixIRCd.Tables.UserMonitor
  alias Memento.Query.Data

  @doc """
  Creates a new user monitor entry.
  """
  @spec create(map()) :: UserMonitor.t()
  def create(attrs) do
    UserMonitor.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Gets all monitored targets for a given user.
  """
  @spec get_by_user_pid(pid()) :: [UserMonitor.t()]
  def get_by_user_pid(user_pid) do
    :mnesia.read(UserMonitor, user_pid)
    |> Enum.map(&Data.load/1)
  end

  @doc """
  Gets all users monitoring a specific target nick.
  """
  @spec get_by_target_nick_key(String.t()) :: [UserMonitor.t()]
  def get_by_target_nick_key(target_nick_key) do
    :mnesia.index_read(UserMonitor, target_nick_key, :target_nick_key)
    |> Enum.map(&Data.load/1)
  end

  @doc """
  Counts the number of targets a user is monitoring.
  """
  @spec count_by_user_pid(pid()) :: non_neg_integer()
  def count_by_user_pid(user_pid) do
    :mnesia.read(UserMonitor, user_pid)
    |> Enum.count()
  end

  @doc """
  Checks if a user is already monitoring a specific target.
  """
  @spec exists?(pid(), String.t()) :: boolean()
  def exists?(user_pid, target_nick_key) do
    :mnesia.read(UserMonitor, user_pid)
    |> Enum.map(&Data.load/1)
    |> Enum.any?(fn record -> record.target_nick_key == target_nick_key end)
  end

  @doc """
  Deletes a specific monitor entry.
  """
  @spec delete(pid(), String.t()) :: :ok
  def delete(user_pid, target_nick_key) do
    :mnesia.read(UserMonitor, user_pid)
    |> Enum.map(&Data.load/1)
    |> Enum.filter(fn record -> record.target_nick_key == target_nick_key end)
    |> Enum.each(&Memento.Query.delete_record/1)

    :ok
  end

  @doc """
  Deletes all monitor entries for a user.
  """
  @spec delete_by_user_pid(pid()) :: :ok
  def delete_by_user_pid(user_pid) do
    :mnesia.read(UserMonitor, user_pid)
    |> Enum.map(&Data.load/1)
    |> Enum.each(&Memento.Query.delete_record/1)

    :ok
  end
end
