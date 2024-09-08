defmodule ElixIRCd do
  @moduledoc """
  ElixIRCd is an IRC server written in Elixir.
  """

  use Application

  require Logger

  import ElixIRCd.Utils, only: [logger_with_time: 3]

  @impl true
  def start(_type, _args) do
    startup_version_info()
    prepare_database()
    generate_certificate()

    Application.put_env(:elixircd, :app_start_time, DateTime.utc_now())

    logger_with_time(:info, "starting server supervisor", fn ->
      Supervisor.start_link([ElixIRCd.Server.Supervisor], strategy: :one_for_one, name: __MODULE__)
    end)
  end

  @spec startup_version_info :: :ok
  defp startup_version_info do
    Logger.info("ElixIRCd version #{Application.spec(:elixircd, :vsn)}")
    Logger.info("Powered by Elixir #{System.version()} (Erlang/OTP #{:erlang.system_info(:otp_release)})")
  end

  @spec prepare_database :: :ok
  defp prepare_database do
    logger_with_time(:info, "preparing Mnesia database", fn ->
      Mix.Task.run("db.prepare", ["--quiet"])
    end)
  end

  # generates self-signed certificate if it is configured and does not exist yet
  # this is for development and testing purposes only; for real-world use, you should use a trusted certificate
  @spec generate_certificate :: :ok
  defp generate_certificate do
    # Self-signed certificate generation is already tested in the `gen.cert` Mix task.
    # coveralls-ignore-start
    if Enum.any?(Application.get_env(:elixircd, :listeners), &should_generate_certificate?/1) do
      logger_with_time(:info, "generating self-signed certificate for SSL listeners", fn ->
        Mix.Task.run("gen.cert", [])
      end)
    end

    # coveralls-ignore-stop
    :ok
  end

  @spec should_generate_certificate?({:tcp | :ssl, keyword()}) :: boolean()
  defp should_generate_certificate?({:ssl, ssl_opts}) do
    keyfile = Keyword.get(ssl_opts, :keyfile)
    certfile = Keyword.get(ssl_opts, :certfile)

    keyfile == "priv/cert/selfsigned_key.pem" and certfile == "priv/cert/selfsigned.pem" and
      (!File.exists?(keyfile) or !File.exists?(certfile))
  end

  defp should_generate_certificate?(_listener), do: false
end
