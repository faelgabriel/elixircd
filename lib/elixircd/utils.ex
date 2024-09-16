defmodule ElixIRCd.Utils do
  @moduledoc """
  Module for general utility functions.
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
    Path.join(["config", "elixircd.exs"])
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
  @spec should_generate_certificate?() :: boolean()
  def should_generate_certificate? do
    Enum.any?(Application.get_env(:elixircd, :listeners), fn
      {:ssl, ssl_opts} ->
        keyfile = Keyword.get(ssl_opts, :keyfile)
        certfile = Keyword.get(ssl_opts, :certfile)

        keyfile == "priv/cert/selfsigned_key.pem" and certfile == "priv/cert/selfsigned.pem" and
          (!File.exists?(keyfile) or !File.exists?(certfile))

      _ ->
        false
    end)
  end

  @doc """
  Retrieves the user identifier from an Ident server.
  """
  # Mimic library does not support mocking of sticky modules (e.g. :gen_tcp),
  # we need to ignore this module from the test coverage for now.
  # coveralls-ignore-start
  @spec query_identd_userid(tuple(), integer()) :: {:ok, String.t()} | {:error, String.t()}
  def query_identd_userid(ip, irc_server_port) do
    timeout = Application.get_env(:elixircd, :ident_service)[:timeout]

    with {:ok, socket} <- :gen_tcp.connect(ip, 113, [:binary, {:active, false}]),
         :ok <- :gen_tcp.send(socket, "#{irc_server_port}, 113\r\n"),
         {:ok, data} <- :gen_tcp.recv(socket, 0, timeout),
         :ok <- :gen_tcp.close(socket),
         [_port_info, "USERID", _os, user_id] <- String.split(data, " : ", trim: true) do
      {:ok, user_id}
    else
      {:error, reason} -> {:error, "Failed to retrieve Identd response: #{inspect(reason)}"}
      data -> {:error, "Unexpected Identd response: #{inspect(data)}"}
    end
  end

  # coveralls-ignore-stop
end
