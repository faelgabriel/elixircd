defmodule ElixIRCd.Repositories.ClientBatches do
  @moduledoc "Repository for client-originated BATCH state."

  alias ElixIRCd.Tables.ClientBatch
  alias Memento.Query.Data

  @doc "Creates an ephemeral client batch."
  @spec create(map()) :: ClientBatch.t()
  def create(attrs), do: attrs |> ClientBatch.new() |> Memento.Query.write()

  @doc "Updates an existing client batch."
  @spec update(ClientBatch.t(), map()) :: ClientBatch.t()
  def update(batch, attrs), do: batch |> struct!(attrs) |> Memento.Query.write()

  @doc "Deletes a client batch."
  @spec delete(ClientBatch.t()) :: :ok
  def delete(batch), do: Memento.Query.delete_record(batch)

  @doc "Fetches a batch by connection and client reference."
  @spec get(pid(), String.t()) :: {:ok, ClientBatch.t()} | {:error, :client_batch_not_found}
  def get(user_pid, reference) do
    case Memento.Query.read(ClientBatch, {user_pid, reference}) do
      nil -> {:error, :client_batch_not_found}
      batch -> {:ok, batch}
    end
  end

  @doc "Lists all batches owned by a connection."
  @spec for_user(pid()) :: [ClientBatch.t()]
  def for_user(user_pid) do
    :mnesia.index_read(ClientBatch, user_pid, :user_pid) |> Enum.map(&Data.load/1)
  end

  @doc "Deletes all batches owned by a connection."
  @spec delete_by_user_pid(pid()) :: :ok
  def delete_by_user_pid(user_pid) do
    user_pid
    |> for_user()
    |> Enum.each(&delete/1)

    :ok
  end
end
