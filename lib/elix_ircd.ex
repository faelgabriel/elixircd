defmodule ElixIRCd do
  @moduledoc """
  ElixIRCd is an IRC server written in Elixir.
  """

  require Logger

  use Application

  @impl true
  def start(_type, _args) do
    Logger.info("Server starting...")

    children = [
      ElixIRCd.Data.Repo,
      ElixIRCd.Server.Supervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ElixIRCd.Supervisor)
  end

  @impl true
  def stop(_state) do
    Logger.info("Server shutting down...")
    :ok
  end
end
