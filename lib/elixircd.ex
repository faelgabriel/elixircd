defmodule ElixIRCd do
  @moduledoc """
  ElixIRCd is an IRC server written in Elixir.
  """

  use Application

  require Logger

  import ElixIRCd.Utils, only: [load_configurations: 0, logger_with_time: 3, should_generate_certificate?: 0]

  @impl true
  def start(_type, _args) do
    version_info()
    init_config()
    init_database()
    generate_certificate()

    Application.put_env(:elixircd, :app_start_time, DateTime.utc_now())

    logger_with_time(:info, "starting server supervisor", fn ->
      Supervisor.start_link([ElixIRCd.Server.Supervisor], strategy: :one_for_one, name: __MODULE__)
    end)
  end

  @spec version_info :: :ok
  defp version_info do
    Logger.info("ElixIRCd version #{Application.spec(:elixircd, :vsn)}")
    Logger.info("Powered by Elixir #{System.version()} (Erlang/OTP #{:erlang.system_info(:otp_release)})")
  end

  @spec init_config :: :ok
  defp init_config do
    logger_with_time(:info, "loading configurations", fn ->
      load_configurations()
    end)
  end

  @spec init_database :: :ok
  defp init_database do
    logger_with_time(:info, "loading database", fn ->
      Mix.Task.run("db.prepare", ["--quiet"])
    end)
  end

  # generates self-signed certificate if it is configured and does not exist yet
  # this is for development and testing purposes only; for real-world use, you should use a trusted certificate
  @spec generate_certificate :: :ok
  defp generate_certificate do
    # Self-signed certificate generation is already tested in the `gen.cert` Mix task.
    # coveralls-ignore-start
    if should_generate_certificate?() do
      logger_with_time(:info, "generating self-signed certificate", fn ->
        Mix.Task.run("gen.cert", [])
      end)
    end

    # coveralls-ignore-stop
  end
end
