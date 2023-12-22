defmodule ElixIRCd.Supervisors.SslSupervisor do
  @moduledoc """
  Supervisor for the SSL server.
  """

  require Logger

  use Supervisor

  @doc """
  Starts the SSL server supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    opts = [
      {:port, Application.get_env(:elixircd, :ssl_port)},
      {:keyfile, Application.get_env(:elixircd, :ssl_keyfile)},
      {:certfile, Application.get_env(:elixircd, :ssl_certfile)}
    ]

    children = [
      :ranch.child_spec(__MODULE__, :ranch_ssl, opts, ElixIRCd.Protocols.SslServer, [])
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
