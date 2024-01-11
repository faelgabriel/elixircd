defmodule ElixIRCd.Server.Supervisor do
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
    tcp_children = tcp_child_specs()
    ssl_children = ssl_child_specs()

    Supervisor.init(tcp_children ++ ssl_children, strategy: :one_for_one)
  end

  @spec tcp_child_specs() :: [Supervisor.child_spec()]
  defp tcp_child_specs do
    tcp_ports = Application.get_env(:elixircd, :tcp_ports)

    Enum.map(tcp_ports, fn port ->
      opts = [{:port, port}]
      create_child_spec(:ranch_tcp, port, opts)
    end)
  end

  @spec ssl_child_specs() :: [Supervisor.child_spec()]
  defp ssl_child_specs do
    ssl_keyfile = Application.get_env(:elixircd, :ssl_keyfile)
    ssl_certfile = Application.get_env(:elixircd, :ssl_certfile)
    ssl_ports = Application.get_env(:elixircd, :ssl_ports)

    Enum.map(ssl_ports, fn port ->
      opts = [{:port, port}, {:keyfile, ssl_keyfile}, {:certfile, ssl_certfile}]
      create_child_spec(:ranch_ssl, port, opts)
    end)
  end

  @spec create_child_spec(:ranch_tcp | :ranch_ssl, integer(), keyword()) :: Supervisor.child_spec()
  defp create_child_spec(transport, port, opts) do
    :ranch.child_spec({__MODULE__, port}, transport, opts, ElixIRCd.Server, [])
  end
end
