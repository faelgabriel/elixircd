defmodule ElixIRCd do
  @moduledoc """
  ElixIRCd is an IRC server written in Elixir.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting ElixIRCd application")

    prepare_database()
    generate_certificate()

    Application.put_env(:elixircd, :app_start_time, DateTime.utc_now())
    Supervisor.start_link([ElixIRCd.Server.Supervisor], strategy: :one_for_one, name: __MODULE__)
  end

  @spec prepare_database :: :ok
  defp prepare_database do
    Logger.info("Preparing Mnesia database")
    Mix.Task.run("db.prepare", ["--quiet"])
  end

  # generates self-signed certificate if it is configured and does not exist yet
  # this is for development and testing purposes only; for real-world use, you should use a proper certificate
  @spec generate_certificate :: :ok
  defp generate_certificate do
    if Enum.find(Application.get_env(:elixircd, :listeners), &should_generate_certificate?/1) do
      Logger.info("Generating self-signed certificate for SSL")
      Mix.Task.run("gen.cert", [])
    end

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
