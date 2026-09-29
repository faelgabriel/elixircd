defmodule ElixIRCd.CLI.Config do
  @moduledoc "Offline configuration checks for the release CLI."

  alias ElixIRCd.Config.Error
  alias ElixIRCd.Config.Loader

  @usage "Usage: elixircd config check"

  @doc "Checks the bundled configuration or shows command help."
  @spec run([String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def run(args) when args in [[], ["help"], ["--help"], ["-h"]] do
    {:ok, @usage <> "\n\nValidate config/elixircd.exs and its resources without changing the running server."}
  end

  def run(["check"]) do
    Loader.check!("config/elixircd.exs")
    {:ok, "Configuration is valid"}
  rescue
    error in Error -> {:error, Exception.message(error)}
    _ -> {:error, "Could not check config/elixircd.exs; check the file and referenced resources"}
  end

  def run(_args), do: {:error, "Invalid config arguments\n\n#{@usage}"}
end
