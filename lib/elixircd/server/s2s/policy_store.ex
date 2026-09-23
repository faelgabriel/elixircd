defmodule ElixIRCd.Server.S2S.PolicyStore do
  @moduledoc "Durable authority epoch and public policy revision boundary."

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Tables.NativePolicyState

  @key "global"

  @doc "Returns the durable policy identity, or nil while storage is unavailable."
  @spec read() :: %{epoch: Identity.id(), revision: non_neg_integer()} | nil
  def read do
    transaction(fn ->
      case :mnesia.read(NativePolicyState, @key) do
        [{NativePolicyState, @key, epoch, revision}] ->
          %{epoch: epoch, revision: revision}

        _ ->
          nil
      end
    end)
  end

  @doc "Creates the authority policy identity once during database setup."
  @spec ensure!() :: %{epoch: Identity.id(), revision: non_neg_integer()}
  def ensure! do
    Memento.transaction!(fn ->
      case :mnesia.read(NativePolicyState, @key, :write) do
        [{NativePolicyState, @key, epoch, revision}] ->
          %{epoch: epoch, revision: revision}

        [] ->
          state = NativePolicyState.new()
          :mnesia.write(Memento.Query.Data.dump(state))
          %{epoch: state.epoch, revision: state.revision}
      end
    end)
  end

  @doc "Persists a revision without allowing an authority rollback."
  @spec persist_revision(Identity.id(), non_neg_integer()) :: :ok | {:error, term()}
  def persist_revision(epoch, revision)
      when is_binary(epoch) and is_integer(revision) and revision >= 0 do
    case transaction(fn ->
           case :mnesia.read(NativePolicyState, @key, :write) do
             [{NativePolicyState, @key, ^epoch, current}] when revision >= current ->
               :mnesia.write({NativePolicyState, @key, epoch, revision})
               :ok

             [{NativePolicyState, @key, _other_epoch, _current}] ->
               {:error, :policy_epoch_mismatch}

             [] ->
               :mnesia.write({NativePolicyState, @key, epoch, revision})
               :ok
           end
         end) do
      :ok -> :ok
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
      nil -> {:error, :storage_unavailable}
    end
  end

  def persist_revision(_epoch, _revision), do: {:error, :invalid_policy_revision}

  @doc "Allocates the next authority revision under the Mnesia write lock."
  @spec next_revision(Identity.id(), non_neg_integer()) :: {:ok, pos_integer()} | {:error, term()}
  def next_revision(epoch, minimum_revision)
      when is_binary(epoch) and is_integer(minimum_revision) and minimum_revision >= 0 do
    case transaction(fn ->
           case :mnesia.read(NativePolicyState, @key, :write) do
             [{NativePolicyState, @key, ^epoch, current}] ->
               revision = max(current + 1, minimum_revision + 1)
               :mnesia.write({NativePolicyState, @key, epoch, revision})
               {:ok, revision}

             [{NativePolicyState, @key, _other_epoch, _current}] ->
               {:error, :policy_epoch_mismatch}

             [] ->
               revision = max(minimum_revision + 1, 1)
               :mnesia.write({NativePolicyState, @key, epoch, revision})
               {:ok, revision}
           end
         end) do
      {:ok, _revision} = result -> result
      {:error, _} = error -> error
      nil -> {:error, :storage_unavailable}
    end
  end

  def next_revision(_epoch, _minimum_revision), do: {:error, :invalid_policy_revision}

  defp transaction(fun) do
    if Memento.Transaction.inside?() do
      fun.()
    else
      case :mnesia.transaction(fun) do
        {:atomic, value} -> value
        {:aborted, _reason} -> nil
      end
    end
  end
end
