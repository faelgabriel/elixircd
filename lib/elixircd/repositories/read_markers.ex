defmodule ElixIRCd.Repositories.ReadMarkers do
  @moduledoc "Repository for account-scoped read markers."

  alias ElixIRCd.Tables.ReadMarker
  alias Memento.Query.Data

  @doc "Fetches an owner's marker for a normalized target."
  @spec get(String.t(), String.t()) :: {:ok, ReadMarker.t()} | {:error, :read_marker_not_found}
  def get(owner_key, target_key) do
    case Memento.Query.read(ReadMarker, {owner_key, target_key}) do
      nil -> {:error, :read_marker_not_found}
      marker -> {:ok, marker}
    end
  end

  @doc "Stores an owner's marker for a target."
  @spec put(String.t(), String.t(), String.t(), DateTime.t()) :: ReadMarker.t()
  def put(owner_key, target_key, target, timestamp) do
    now = DateTime.utc_now()

    %{
      id: {owner_key, target_key},
      owner_key: owner_key,
      target_key: target_key,
      target: target,
      timestamp: timestamp,
      updated_at: now
    }
    |> ReadMarker.new()
    |> Memento.Query.write()
  end

  @doc "Deletes all markers belonging to a disconnected anonymous session."
  @spec delete_owner(String.t()) :: :ok
  def delete_owner(owner_key) do
    :mnesia.index_read(ReadMarker, owner_key, :owner_key)
    |> Enum.map(&Data.load/1)
    |> Enum.each(&Memento.Query.delete_record/1)

    :ok
  end

  @doc "Counts the bounded set of targets stored for one owner."
  @spec count_owner(String.t()) :: non_neg_integer()
  def count_owner(owner_key), do: :mnesia.index_read(ReadMarker, owner_key, :owner_key) |> length()

  @doc "Moves a bounded session set into an account, keeping the newest marker per target."
  @spec migrate_owner(String.t(), String.t(), pos_integer()) :: :ok
  def migrate_owner(session_owner, account_owner, max_targets) do
    :mnesia.index_read(ReadMarker, session_owner, :owner_key)
    |> Enum.map(&Data.load/1)
    |> Enum.each(fn marker ->
      merge_marker(marker, account_owner, max_targets)
      Memento.Query.delete_record(marker)
    end)

    :ok
  end

  defp merge_marker(marker, account_owner, max_targets) do
    case get(account_owner, marker.target_key) do
      {:ok, existing} ->
        if DateTime.compare(marker.timestamp, existing.timestamp) == :gt do
          put(account_owner, marker.target_key, marker.target, marker.timestamp)
        end

      {:error, :read_marker_not_found} ->
        if count_owner(account_owner) < max_targets do
          put(account_owner, marker.target_key, marker.target, marker.timestamp)
        end
    end
  end

  @doc "Removes abandoned session markers after a restart or missed disconnect."
  @spec prune_abandoned_sessions(DateTime.t(), MapSet.t(String.t())) :: :ok
  def prune_abandoned_sessions(cutoff, active_sessions) do
    Memento.Query.all(ReadMarker)
    |> Enum.filter(fn marker ->
      String.starts_with?(marker.owner_key, "session:") and
        not MapSet.member?(active_sessions, marker.owner_key) and
        DateTime.compare(marker.updated_at, cutoff) == :lt
    end)
    |> Enum.each(&Memento.Query.delete_record/1)

    :ok
  end
end
