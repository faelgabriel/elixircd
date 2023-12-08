defmodule ElixIRCd do
  @moduledoc """
  ElixIRCd is an IRC server written in Elixir.
  """

  require Logger

  use Application

  @impl true
  def start(_type, _args) do
    tcp_opts = [{:port, 6667}]

    ssl_opts = [
      {:port, 6697},
      {:certfile, "priv/cert/server.crt"},
      {:keyfile, "priv/cert/server.pem"}
    ]

    children = [
      {ElixIRCd.Data.Repo, []},
      {ElixIRCd.Supervisors.TcpSupervisor, tcp_opts},
      {ElixIRCd.Supervisors.SslSupervisor, ssl_opts},
      {Registry, keys: :unique, name: ElixIRCd.Protocols.Registry}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ElixIRCd.Supervisor)
  end

  @impl true
  def stop(_state) do
    Logger.info("Server shutting down...")
    :ok
  end
end
