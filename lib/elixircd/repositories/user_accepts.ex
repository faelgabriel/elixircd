defmodule ElixIRCd.Repositories.UserAccepts do
  @moduledoc """
  Repository for managing user accept lists.
  """

  alias ElixIRCd.Tables.UserAccept
  alias ElixIRCd.Repositories.Users
  alias Memento.Query.Data

  @doc """
  Creates a new user accept entry.
  """
  @spec create(map()) :: UserAccept.t()
  def create(attrs) do
    attrs
    |> put_uids()
    |> UserAccept.new()
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

  @doc "Gets a specific accept entry by the recipient PID and accepted stable UID."
  @spec get_by_user_pid_and_accepted_uid(pid(), String.t()) :: UserAccept.t() | nil
  def get_by_user_pid_and_accepted_uid(user_pid, accepted_uid) when is_pid(user_pid) and is_binary(accepted_uid) do
    get_by_user_pid(user_pid)
    |> Enum.find(fn record ->
      record.accepted_user_uid == accepted_uid or
        (is_nil(record.accepted_user_uid) and uid_for_pid(record.accepted_user_pid) == accepted_uid)
    end)
  end

  def get_by_user_pid_and_accepted_uid(_user_pid, _accepted_uid), do: nil

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

  @doc "Deletes an accept entry by recipient PID and accepted stable UID."
  @spec delete_by_user_pid_and_accepted_uid(pid(), String.t()) :: :ok
  def delete_by_user_pid_and_accepted_uid(user_pid, accepted_uid)
      when is_pid(user_pid) and is_binary(accepted_uid) do
    case get_by_user_pid_and_accepted_uid(user_pid, accepted_uid) do
      nil -> :ok
      record -> Memento.Query.delete_record(record)
    end

    :ok
  end

  def delete_by_user_pid_and_accepted_uid(_user_pid, _accepted_uid), do: :ok

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

  @doc "Deletes entries that reference an accepted stable UID."
  @spec delete_by_accepted_user_uid(String.t()) :: :ok
  def delete_by_accepted_user_uid(accepted_uid) when is_binary(accepted_uid) do
    :mnesia.foldl(
      fn raw, _acc ->
        record = Data.load(raw)

        if record.accepted_user_uid == accepted_uid or
             (is_nil(record.accepted_user_uid) and uid_for_pid(record.accepted_user_pid) == accepted_uid),
           do: Memento.Query.delete_record(record),
           else: :ok

        :ok
      end,
      :ok,
      UserAccept
    )

    :ok
  end

  def delete_by_accepted_user_uid(_accepted_uid), do: :ok

  defp put_uids(attrs) do
    attrs
    |> Map.put_new(:user_uid, uid_for_pid(Map.get(attrs, :user_pid)))
    |> Map.put_new(:accepted_user_uid, uid_for_pid(Map.get(attrs, :accepted_user_pid)))
  end

  defp uid_for_pid(pid) when is_pid(pid) do
    case Users.uid_for_pid(pid) do
      {:ok, uid} -> uid
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp uid_for_pid(_pid), do: nil
end
