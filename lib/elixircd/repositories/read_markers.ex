defmodule ElixIRCd.Repositories.ReadMarkers do
  @moduledoc "Repository for account-scoped read markers."

  alias ElixIRCd.Tables.ReadMarker

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
end
