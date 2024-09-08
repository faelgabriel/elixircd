defmodule ElixIRCd.Tables.Metric do
  @moduledoc """
  Module for the Metric table.
  """

  @enforce_keys [:key, :value]
  use Memento.Table,
    attributes: [
      :key,
      :value
    ],
    type: :set

  @type t :: %__MODULE__{
          key: atom(),
          value: integer()
        }

  @type key :: :highest_connections | :total_connections
end
