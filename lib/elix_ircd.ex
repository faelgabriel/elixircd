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
      {:cacertfile, "priv/cert/ca.pem"},
      {:keyfile, "priv/cert/server.pem"}
    ]

    children = [
      {ElixIRCd.Repo, []},
      {ElixIRCd.Listeners.TcpListener, tcp_opts},
      {ElixIRCd.Listeners.SslListener, ssl_opts}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ElixIRCd.Supervisor)
  end
end
