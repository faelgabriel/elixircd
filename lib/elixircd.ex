defmodule ElixIRCd do
  @moduledoc """
  ElixIRCd is an IRC server written in Elixir.
  """

  use Application

  require Logger

  import ElixIRCd.Utils.Certificate, only: [create_self_signed_certificate: 0]
  import ElixIRCd.Utils.Mnesia, only: [setup_mnesia: 0]
  import ElixIRCd.Utils.System, only: [load_configurations: 0, logger_with_time: 3, should_generate_certificate?: 0]

  @impl true
  def start(_type, _args) do
    Logger.info("ElixIRCd version #{Application.spec(:elixircd, :vsn)}")
    Logger.info("Powered by Elixir #{System.version()} (Erlang/OTP #{:erlang.system_info(:otp_release)})")

    init_config()
    init_database()
    ensure_certificate_exists()

    :persistent_term.put(:app_start_time, DateTime.utc_now())
    Supervisor.start_link([
      ElixIRCd.Server.Supervisor,
      ElixIRCd.Utils.NicknameExpirationScheduler
    ], strategy: :one_for_one, name: __MODULE__)
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
      setup_mnesia()
    end)
  end

  # generates self-signed certificate if it is configured and does not exist yet
  # this is for development and testing purposes only; for real-world use, you should use a trusted certificate
  @spec ensure_certificate_exists :: :ok
  defp ensure_certificate_exists do
    # Self-signed certificate generation is already tested in the Certificate module.
    # coveralls-ignore-start
    if should_generate_certificate?() do
      logger_with_time(:info, "generating self-signed certificate", fn ->
        create_self_signed_certificate()
      end)
    end

    # coveralls-ignore-stop
  end
end
