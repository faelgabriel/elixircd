defmodule ElixIRCd.Repositories.MetadataSubscriptions do
  @moduledoc "Session-local IRCv3 metadata subscriptions."

  alias ElixIRCd.Tables.MetadataSubscription
  alias Memento.Query.Data

  @doc "Subscribes a connection to a metadata key."
  @spec subscribe(pid(), String.t()) :: MetadataSubscription.t()
  def subscribe(user_pid, key), do: MetadataSubscription.new(user_pid, key) |> Memento.Query.write()

  @doc "Removes a connection's subscription to a metadata key."
  @spec unsubscribe(pid(), String.t()) :: :ok
  def unsubscribe(user_pid, key), do: Memento.Query.delete(MetadataSubscription, {user_pid, key})

  @doc "Lists the keys subscribed by a connection."
  @spec list(pid()) :: [String.t()]
  def list(user_pid) do
    :mnesia.index_read(MetadataSubscription, user_pid, :user_pid)
    |> Enum.map(&Data.load/1)
    |> Enum.map(& &1.key)
    |> Enum.sort()
  end

  @doc "Checks whether a connection is subscribed to a key."
  @spec subscribed?(pid(), String.t()) :: boolean()
  def subscribed?(user_pid, key), do: Memento.Query.read(MetadataSubscription, {user_pid, key}) != nil

  @doc "Lists connections subscribed to a key."
  @spec subscribers(String.t()) :: [pid()]
  def subscribers(key) do
    :mnesia.index_read(MetadataSubscription, key, :key)
    |> Enum.map(&Data.load/1)
    |> Enum.map(& &1.user_pid)
  end

  @doc "Deletes every metadata subscription owned by a connection."
  @spec delete_by_user_pid(pid()) :: :ok
  def delete_by_user_pid(user_pid) do
    :mnesia.index_read(MetadataSubscription, user_pid, :user_pid)
    |> Enum.each(&:mnesia.delete_object/1)

    :ok
  end
end
