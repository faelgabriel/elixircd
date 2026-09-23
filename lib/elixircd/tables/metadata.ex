defmodule ElixIRCd.Tables.Metadata do
  @moduledoc "Persistent IRCv3 metadata attached to an account or channel."

  use Memento.Table,
    attributes: [:id, :target_type, :target_key, :key, :value, :visibility, :updated_at],
    index: [:target_key],
    type: :set

  @type t :: %__MODULE__{
          id: {atom(), String.t(), String.t()},
          target_type: :account | :channel | :session,
          target_key: String.t(),
          key: String.t(),
          value: String.t(),
          visibility: String.t(),
          updated_at: DateTime.t()
        }

  @doc "Builds a metadata entry with public visibility and a current update time by default."
  @spec new(map()) :: t()
  def new(attrs) do
    attrs
    |> Map.put_new(:visibility, "*")
    |> Map.put_new(:updated_at, DateTime.utc_now())
    |> then(&struct!(__MODULE__, &1))
  end
end
