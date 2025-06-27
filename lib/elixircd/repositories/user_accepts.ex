defmodule ElixIRCd.Repositories.UserAccepts do
  @moduledoc """
  Repository for managing user accept lists.
  """

  alias ElixIRCd.Tables.UserAccept
  alias Memento.Query.Data

  @doc """
  Creates a new user accept entry.
  """
  @spec create(map()) :: UserAccept.t()
  def create(attrs) do
    UserAccept.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Gets all accepted users for a given user.
  """
  @spec get_by_user_pid(pid()) :: [UserAccept.t()]
  def get_by_user_pid(user_pid) do
    :mnesia.read(UserAccept, user_pid)
    |> Enum.map(&Data.load/1)
  end

  @doc """
  Gets a specific accept entry by user pid and accepted user pid.
  """
  @spec get_by_user_pid_and_accepted_user_pid(pid(), pid()) :: UserAccept.t() | nil
  def get_by_user_pid_and_accepted_user_pid(user_pid, accepted_user_pid) do
    :mnesia.read(UserAccept, user_pid)
    |> Enum.map(&Data.load/1)
    |> Enum.find(fn record -> record.accepted_user_pid == accepted_user_pid end)
  end

  @doc """
  Deletes a specific accept entry.
  """
  @spec delete(pid(), pid()) :: :ok
  def delete(user_pid, accepted_user_pid) do
    case get_by_user_pid_and_accepted_user_pid(user_pid, accepted_user_pid) do
      nil -> :ok
      record -> Memento.Query.delete_record(record)
    end

    :ok
  end

  @doc """
  Deletes all accept entries for a user.
  """
  @spec delete_by_user_pid(pid()) :: :ok
  def delete_by_user_pid(user_pid) do
    :mnesia.read(UserAccept, user_pid)
    |> Enum.map(&Data.load/1)
    |> Enum.each(&Memento.Query.delete_record/1)

    :ok
  end

  @doc """
  Deletes all entries where this user is accepted by others.
  """
  @spec delete_by_accepted_user_pid(pid()) :: :ok
  def delete_by_accepted_user_pid(accepted_user_pid) do
    :mnesia.index_read(UserAccept, accepted_user_pid, :accepted_user_pid)
    |> Enum.map(&Data.load/1)
    |> Enum.each(&Memento.Query.delete_record/1)

    :ok
  end
end
