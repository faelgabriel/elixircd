defmodule ElixIRCd.Tables.ReadMarker do
  @moduledoc "Persistent monotonic read marker scoped to an account and target."

  @enforce_keys [:id, :owner_key, :target_key, :target, :timestamp, :updated_at]
  use Memento.Table,
    attributes: [:id, :owner_key, :target_key, :target, :timestamp, :updated_at],
    index: [:owner_key, :target_key],
    type: :set

  @type t :: %__MODULE__{
          id: {String.t(), String.t()},
          owner_key: String.t(),
          target_key: String.t(),
          target: String.t(),
          timestamp: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Builds a persisted read marker."
  @spec new(map()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
