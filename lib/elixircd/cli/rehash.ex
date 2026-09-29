defmodule ElixIRCd.CLI.Rehash do
  @moduledoc "Reloads the running server from the release CLI."

  alias ElixIRCd.CLI.Remote
  alias ElixIRCd.Commands.Rehash
  alias ElixIRCd.Config.Error

  @usage "Usage: elixircd rehash"

  @doc "Runs a remote rehash or shows command help."
  @spec run([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def run(args) when args in [[], ["help"], ["--help"], ["-h"]] do
    if args == [], do: rehash(), else: {:ok, @usage <> "\n\nReload config/elixircd.exs on the running server."}
  end

  def run(_args), do: {:error, "Invalid rehash arguments\n\n#{@usage}"}

  defp rehash do
    with {:ok, server_node} <- Remote.connect("rehash") do
      case Remote.call(server_node, Rehash, :run_cli, []) do
        :ok -> {:ok, "Configuration reloaded"}
        {:error, %Error{errors: errors}} -> {:error, format_errors(errors)}
        _ -> {:error, "Could not reload configuration; check config/elixircd.exs and server logs"}
      end
    end
  end

  defp format_errors(errors) do
    details = errors |> Enum.take(5) |> Enum.map_join("\n", &"  - #{&1}")
    "Could not reload configuration:\n" <> details
  end
end
