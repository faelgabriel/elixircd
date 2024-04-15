defmodule ElixIRCd do
  @moduledoc """
  ElixIRCd is an IRC server written in Elixir.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Application.put_env(:elixircd, :app_start_time, DateTime.utc_now())

    children = [
      ElixIRCd.Server.Supervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ElixIRCd.Supervisor)
  end
end
