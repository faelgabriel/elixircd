defmodule ElixIRCd.CLI do
  @moduledoc "Entrypoint for administrative commands in the release."

  @commands %{
    "config" => {ElixIRCd.CLI.Config, "Check configuration"},
    "oper" => {ElixIRCd.Operators.CLI, "Manage IRC operators"},
    "rehash" => {ElixIRCd.CLI.Rehash, "Reload running server configuration"}
  }

  @doc "Runs a command and returns text to print or an error."
  @spec run([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def run(args)

  def run([]), do: {:ok, help()}
  def run([option]) when option in ["help", "--help", "-h"], do: {:ok, help()}

  def run(["help", command | rest]), do: command_help(command, rest)
  def run([command | args]), do: dispatch(command, args)

  @doc "Prints the result and exits with the appropriate status."
  @spec main([String.t()]) :: no_return()
  def main(args) do
    case run(args) do
      {:ok, output} ->
        IO.puts(output)
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, reason)
        System.halt(1)
    end
  end

  defp dispatch(command, args) do
    case Map.fetch(@commands, command) do
      {:ok, {module, _summary}} -> module.run(args)
      :error -> {:error, "Unknown command: #{command}\n\n#{help()}"}
    end
  end

  defp command_help(command, rest) do
    case Map.fetch(@commands, command) do
      {:ok, {module, _summary}} -> module.run(["help" | rest])
      :error -> {:error, "Unknown command: #{command}\n\n#{help()}"}
    end
  end

  defp help do
    commands =
      @commands
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map_join("\n", fn {name, {_module, summary}} -> "  #{name}  #{summary}" end)

    """
    Usage: elixircd COMMAND [ARGS]

    Commands:
    #{commands}

    Run 'elixircd help COMMAND' for command details.
    """
    |> String.trim_trailing()
  end
end
