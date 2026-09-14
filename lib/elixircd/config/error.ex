defmodule ElixIRCd.Config.Error do
  @moduledoc "Configuration failure with field paths and safe messages, never secret values."
  defexception [:path, errors: []]

  @type t :: %__MODULE__{path: String.t(), errors: [String.t()]}

  @impl true
  def message(%{path: path, errors: errors}) do
    "Invalid configuration #{path}:\n" <> Enum.map_join(errors, "\n", &"  - #{&1}")
  end
end
