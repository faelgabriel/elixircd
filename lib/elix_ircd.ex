defmodule ElixIRCd do
  @moduledoc """
  ElixIRCd is an IRC server written in Elixir.
  """

  require Logger

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ElixIRCd.Data.Repo,
      ElixIRCd.Supervisors.TcpSupervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ElixIRCd.Supervisor)
  end

  @impl true
  def stop(_state) do
    Logger.info("Server shutting down...")
    :ok
  end
end
