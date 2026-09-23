defmodule ElixIRCd.Tables.NativeOutputGroup do
  @moduledoc "Transient committed output groups for the local effect barrier."

  @enforce_keys [:id, :generation, :intents, :bytes, :destinations]
  use Memento.Table,
    attributes: [:id, :generation, :intents, :bytes, :destinations],
    type: :set

  @type t :: %__MODULE__{
          id: pos_integer(),
          generation: String.t(),
          intents: [map()],
          bytes: pos_integer(),
          destinations: [term()]
        }

  @doc "Builds one bounded committed output group."
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    struct!(__MODULE__, %{
      id: Map.fetch!(attrs, :id),
      generation: Map.fetch!(attrs, :generation),
      intents: Map.fetch!(attrs, :intents),
      bytes: Map.fetch!(attrs, :bytes),
      destinations: Map.fetch!(attrs, :destinations)
    })
  end
end
