defmodule ElixIRCd.Repositories.UserAcceptRemotes do
  @moduledoc "Local +g permissions for authenticated remote user identities."

  alias ElixIRCd.Tables.UserAcceptRemote
  alias Memento.Query.Data

  @type identity :: UserAcceptRemote.identity()

  @doc "Adds one remote UID to a local recipient's accept list."
  @spec create(pid(), identity()) :: UserAcceptRemote.t()
  def create(user_pid, identity) do
    UserAcceptRemote.new(user_pid, identity)
    |> Memento.Query.write()
  end

  @doc "Finds all remote UIDs accepted by one local recipient."
  @spec get_by_user_pid(pid()) :: [UserAcceptRemote.t()]
  def get_by_user_pid(user_pid) do
    :mnesia.read(UserAcceptRemote, user_pid)
    |> Enum.map(&Data.load/1)
  end

  @doc "Checks one exact remote home and UID, independent of nickname changes."
  @spec get_by_user_pid_and_identity(pid(), identity()) :: UserAcceptRemote.t() | nil
  def get_by_user_pid_and_identity(user_pid, identity) do
    get_by_user_pid(user_pid)
    |> Enum.find(&(&1.accepted_identity == identity))
  end

  @doc "Removes one accepted remote UID from a local recipient's list."
  @spec delete(pid(), identity()) :: :ok
  def delete(user_pid, identity) do
    case get_by_user_pid_and_identity(user_pid, identity) do
      nil -> :ok
      record -> Memento.Query.delete_record(record)
    end

    :ok
  end

  @doc "Removes all remote permissions owned by a local recipient."
  @spec delete_by_user_pid(pid()) :: :ok
  def delete_by_user_pid(user_pid) do
    get_by_user_pid(user_pid)
    |> Enum.each(&Memento.Query.delete_record/1)

    :ok
  end

  @doc "Revokes a departed remote UID from every local accept list."
  @spec delete_by_identity(identity()) :: :ok
  def delete_by_identity(identity) do
    :mnesia.index_read(UserAcceptRemote, identity, :accepted_identity)
    |> Enum.map(&Data.load/1)
    |> Enum.each(&Memento.Query.delete_record/1)

    :ok
  end
end
