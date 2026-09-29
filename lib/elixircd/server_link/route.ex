defmodule ElixIRCd.ServerLink.Route do
  @moduledoc "An authenticated next hop and the path from one origin to this server."

  @enforce_keys [:via, :epoch, :path]
  defstruct [:via, :epoch, :path]

  @type t :: %__MODULE__{via: String.t(), epoch: String.t(), path: [String.t()]}
end
