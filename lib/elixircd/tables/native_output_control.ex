defmodule ElixIRCd.Tables.NativeOutputControl do
  @moduledoc "Durable local ENP logical-clock and output ordering control."

  @enforce_keys [:id, :sequence, :logical_counter, :pending_groups, :pending_bytes]
  use Memento.Table,
    attributes: [:id, :sequence, :logical_counter, :pending_groups, :pending_bytes],
    type: :set

  @type t :: %__MODULE__{
          id: String.t(),
          sequence: non_neg_integer(),
          logical_counter: non_neg_integer(),
          pending_groups: non_neg_integer(),
          pending_bytes: non_neg_integer()
        }

  @doc "Builds the single local output ordering row."
  @spec new(keyword() | map()) :: t()
  def new(attrs \\ []) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    struct!(__MODULE__, %{
      id: Map.get(attrs, :id, "local"),
      sequence: Map.get(attrs, :sequence, 0),
      logical_counter: Map.get(attrs, :logical_counter, 0),
      pending_groups: Map.get(attrs, :pending_groups, 0),
      pending_bytes: Map.get(attrs, :pending_bytes, 0)
    })
  end
end
