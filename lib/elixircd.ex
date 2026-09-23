defmodule ElixIRCd do
  @moduledoc """
  ElixIRCd is an IRC server written in Elixir.
  """

  use Application

  require Logger

  import ElixIRCd.Utils.Mnesia, only: [setup_mnesia: 0]
  import ElixIRCd.Utils.System, only: [logger_with_time: 3]

  alias ElixIRCd.Config.Loader

  @impl true
  def start(_type, _args) do
    Logger.info("ElixIRCd version #{Application.spec(:elixircd, :vsn)}")
    Logger.info("Powered by Elixir #{System.version()} (Erlang/OTP #{:erlang.system_info(:otp_release)})")

    init_config()
    init_database()

    :persistent_term.put(:app_start_time, DateTime.utc_now())

    Supervisor.start_link(
      [
        ElixIRCd.Server.RateLimiter,
        ElixIRCd.Server.NickEnforcement,
        ElixIRCd.Server.S2S,
        ElixIRCd.Server.Listeners,
        ElixIRCd.JobQueue
      ],
      strategy: :one_for_one,
      name: __MODULE__
    )
  end

  @spec init_config :: :ok
  defp init_config do
    logger_with_time(:info, "loading configurations", fn ->
      Loader.load!("config/elixircd.exs", :boot)
    end)
  end

  @spec init_database :: :ok
  defp init_database do
    logger_with_time(:info, "loading database", fn ->
      setup_mnesia()
    end)
  end
end
