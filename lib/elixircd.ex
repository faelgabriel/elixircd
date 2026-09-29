defmodule ElixIRCd do
  @moduledoc """
  ElixIRCd is an IRC server written in Elixir.
  """

  use Application

  require Logger

  import ElixIRCd.Utils.Mnesia, only: [setup_mnesia: 0]
  import ElixIRCd.Utils.System, only: [logger_with_time: 3]

  alias ElixIRCd.Config.Loader
  alias ElixIRCd.Observability

  @config_path "config/elixircd.exs"

  @impl true
  def start(_type, _args) do
    Logger.info("ElixIRCd version #{Application.spec(:elixircd, :vsn)}")
    Logger.info("Powered by Elixir #{System.version()} (Erlang/OTP #{:erlang.system_info(:otp_release)})")

    init_database()
    init_config()

    :persistent_term.put(:app_start_time, DateTime.utc_now())

    children = [
      ElixIRCd.Server.RateLimiter,
      ElixIRCd.Server.NickEnforcement,
      ElixIRCd.ServerLink.Supervisor,
      ElixIRCd.Server.Listeners,
      ElixIRCd.JobQueue
    ]

    children = monitored_children(Application.fetch_env!(:elixircd, :observability)[:enabled], children)

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  defp monitored_children(true, children) do
    [Observability.reporter_child_spec(), ElixIRCd.Observability.Poller] ++
      children ++ [{Bandit, Observability.listener_options()}]
  end

  defp monitored_children(false, children), do: children

  @spec init_config :: :ok
  defp init_config do
    logger_with_time(:info, "loading configurations", fn ->
      Loader.load!(@config_path, :boot)
    end)
  end

  @spec init_database :: :ok
  defp init_database do
    logger_with_time(:info, "loading database", fn ->
      setup_mnesia()
    end)
  end
end
