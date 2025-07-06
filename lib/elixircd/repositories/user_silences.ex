defmodule ElixIRCd.Repositories.UserSilences do
  @moduledoc """
  Repository for managing user silence lists.
  """

  alias ElixIRCd.Tables.UserSilence

  @doc """
  Create a new user silence entry.
  """
  @spec create(map()) :: UserSilence.t()
  def create(attrs) do
    UserSilence.new(attrs)
    |> Memento.Query.write()
  end

  @doc """
  Get all silence entries for a user.
  """
  @spec get_by_user_pid(pid()) :: [UserSilence.t()]
  def get_by_user_pid(user_pid) do
    Memento.Query.select(UserSilence, {:==, :user_pid, user_pid})
  end

  @doc """
  Get a specific silence entry by user pid and mask.
  """
  @spec get_by_user_pid_and_mask(pid(), String.t()) :: {:ok, UserSilence.t()} | {:error, :user_silence_not_found}
  def get_by_user_pid_and_mask(user_pid, mask) do
    conditions = [{:==, :user_pid, user_pid}, {:==, :mask, mask}]

    Memento.Query.select(UserSilence, conditions, limit: 1)
    |> case do
      [silence_entry] -> {:ok, silence_entry}
      [] -> {:error, :user_silence_not_found}
    end
  end

  @doc """
  Delete a specific silence entry.
  """
  @spec delete(UserSilence.t()) :: :ok
  def delete(silence_entry) do
    Memento.Query.delete_record(silence_entry)
  end

  @doc """
  Delete all silence entries for a user (cleanup on disconnect).
  """
  @spec delete_by_user_pid(pid()) :: :ok
  def delete_by_user_pid(user_pid) do
    user_pid
    |> get_by_user_pid()
    |> Enum.each(&Memento.Query.delete_record/1)

    :ok
  end
end
