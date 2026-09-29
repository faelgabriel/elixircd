defmodule ElixIRCd.Tables.ChannelIdentity do
  @moduledoc "Remembers the creation server of a locally adopted network channel."

  @enforce_keys [:name_key, :creator]
  use Memento.Table,
    attributes: [:name_key, :creator],
    index: [],
    type: :set

  @type t :: %__MODULE__{name_key: String.t(), creator: String.t()}

  @doc "Builds a channel identity keyed by its normalized IRC name."
  @spec new(String.t(), String.t()) :: t()
  def new(name_key, creator), do: %__MODULE__{name_key: name_key, creator: creator}
end
