defmodule ElixIRCd.Utils.System do
  @moduledoc """
  Module for utility functions related to the system application.
  """

  require Logger

  alias ElixIRCd.Config.Loader

  @doc """
  Loads ElixIRCd configuration file and sets values as application environment variables.

  This custom configuration file is used instead of runtime.exs to ensure consistent loading in various scenarios
  where the configuration is loaded or reloaded, and to allow for a different path for the released configuration file.
  Additionally, it does not use the `config_providers` option because the configuration is loaded manually in certain
  scenarios (e.g., during a REHASH command).
  """
  @spec load_configurations :: :ok
  def load_configurations do
    Loader.load!("config/elixircd.exs", :reload)
  end

  @doc """
  Logs the time taken to execute a function with configurable log level and options.
  """
  @spec logger_with_time(atom(), String.t(), (-> any()), keyword()) :: any()
  def logger_with_time(log_level, message, fun, opts \\ []) when is_function(fun, 0) do
    Logger.log(log_level, "Starting #{message}", opts)

    start_time = System.monotonic_time(:microsecond)
    result = fun.()
    end_time = System.monotonic_time(:microsecond)

    elapsed_time_ms = (end_time - start_time) / 1000
    Logger.log(log_level, "Finished #{message} in #{Float.round(elapsed_time_ms, 2)} ms", opts)

    result
  end
end
