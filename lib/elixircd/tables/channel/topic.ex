defmodule ElixIRCd.Tables.Channel.Topic do
  @moduledoc """
  Module for the Channel.Topic data structure.
  """

  @enforce_keys [:text, :setter, :set_at]
  defstruct [:text, :setter, :set_at]

  @type t :: %__MODULE__{
          text: String.t(),
          setter: String.t(),
          set_at: DateTime.t()
        }
end
