defmodule ElixIRCd.Utils.System do
  @moduledoc """
  Module for utility functions related to the system application.
  """

  require Logger

  @doc """
  Loads ElixIRCd configuration file and sets values as application environment variables.

  This custom configuration file is used instead of runtime.exs to ensure consistent loading in various scenarios
  where the configuration is loaded or reloaded, and to allow for a different path for the released configuration file.
  Additionally, it does not use the `config_providers` option because the configuration is loaded manually in certain
  scenarios (e.g., during a REHASH command).
  """
  @spec load_configurations :: :ok
  def load_configurations do
    Path.join(["data", "config", "elixircd.exs"])
    |> Config.Reader.read!()
    |> Enum.each(fn {app, custom_app_config} ->
      current_app_config = Application.get_all_env(app)
      merged_app_config = Config.Reader.merge([{app, current_app_config}], [{app, custom_app_config}])
      Application.put_all_env(merged_app_config)
    end)
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

  @doc """
  Determines if a self-signed certificate should be generated. This is determined by checking if the configured keyfile
  and certfile are set to the default values and if the files do not exist.
  """
  # We need to ignore this from the test coverage because sometimes the certificate is already generated.
  # coveralls-ignore-start
  @spec should_generate_certificate?() :: boolean()
  def should_generate_certificate? do
    Enum.any?(Application.get_env(:elixircd, :listeners), fn
      {scheme_transport, ssl_opts} when scheme_transport in [:tls, :https] ->
        keyfile = Keyword.get(ssl_opts, :keyfile)
        certfile = Keyword.get(ssl_opts, :certfile)

        keyfile == Path.expand("data/cert/selfsigned_key.pem") and certfile == Path.expand("data/cert/selfsigned.pem") and
          (!File.exists?(keyfile) or !File.exists?(certfile))

      _ ->
        false
    end)
  end

  # coveralls-ignore-stop
end
