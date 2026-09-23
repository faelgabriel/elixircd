defmodule ElixIRCd.Tables.NativePolicyState do
  @moduledoc "Persistent ENP policy epoch and public revision."

  @enforce_keys [:id, :epoch, :revision]
  use Memento.Table,
    attributes: [:id, :epoch, :revision],
    type: :set

  alias ElixIRCd.Server.S2S.Identity

  @type t :: %__MODULE__{
          id: String.t(),
          epoch: Identity.id(),
          revision: non_neg_integer()
        }

  @doc "Builds the persistent native policy epoch and revision record."
  @spec new(keyword() | map()) :: t()
  def new(attrs \\ []) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs

    struct!(__MODULE__, %{
      id: Map.get(attrs, :id, "global"),
      epoch: Map.get(attrs, :epoch, Identity.new_id()),
      revision: Map.get(attrs, :revision, 0)
    })
  end
end
