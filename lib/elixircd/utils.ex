defmodule ElixIRCd.Utils do
  @moduledoc """
  Module for utility functions not specific to the IRC server.
  """

  require Logger

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
