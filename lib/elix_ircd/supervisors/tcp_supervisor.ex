defmodule ElixIRCd.Supervisors.TcpSupervisor do
  @moduledoc """
  Supervisor for the TCP server.
  """

  require Logger

  use Supervisor

  @doc """
  Starts the TCP server supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    opts = [
      {:port, Application.get_env(:elixircd, :tcp_port)},
      :inet6
    ]

    children = [
      :ranch.child_spec(__MODULE__, :ranch_tcp, opts, ElixIRCd.Protocols.TcpServer, [])
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
