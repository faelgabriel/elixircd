defmodule ElixIRCd.Server.Supervisor do
  @moduledoc """
  Supervisor for the SSL server.
  """

  require Logger

  use Supervisor

  @type server_opts ::
          [
            {:tcp_ports, [integer()]}
            | {:ssl_ports, [integer()]}
            | {:ssl_keyfile, String.t()}
            | {:ssl_certfile, String.t()}
            | {:enable_ipv6, boolean()}
          ]

  @doc """
  Starts the server supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_supervisor_opts) do
    server_opts = [
      {:tcp_ports, Application.get_env(:elixircd, :tcp_ports)},
      {:ssl_ports, Application.get_env(:elixircd, :ssl_ports)},
      {:ssl_keyfile, Application.get_env(:elixircd, :ssl_keyfile)},
      {:ssl_certfile, Application.get_env(:elixircd, :ssl_certfile)},
      {:enable_ipv6, Application.get_env(:elixircd, :enable_ipv6)}
    ]

    Supervisor.start_link(__MODULE__, server_opts, name: __MODULE__)
  end

  @impl true
  def init(server_opts) do
    tcp_children = tcp_child_specs(server_opts)
    ssl_children = ssl_child_specs(server_opts)

    Supervisor.init(tcp_children ++ ssl_children, strategy: :one_for_one)
  end

  @spec tcp_child_specs(server_opts()) :: [Supervisor.child_spec()]
  defp tcp_child_specs(server_opts) do
    tcp_ports = Keyword.get(server_opts, :tcp_ports, [])
    enable_ipv6 = Keyword.get(server_opts, :enable_ipv6, false)

    Enum.map(tcp_ports, fn port ->
      opts =
        [{:port, port}]
        |> handle_ipv6_option(enable_ipv6)

      create_child_spec(:ranch_tcp, port, opts)
    end)
  end

  @spec ssl_child_specs(server_opts()) :: [Supervisor.child_spec()]
  defp ssl_child_specs(server_opts) do
    ssl_ports = Keyword.get(server_opts, :ssl_ports, [])
    ssl_keyfile = Keyword.get(server_opts, :ssl_keyfile, nil)
    ssl_certfile = Keyword.get(server_opts, :ssl_certfile, nil)
    enable_ipv6 = Keyword.get(server_opts, :enable_ipv6, false)

    Enum.map(ssl_ports, fn port ->
      opts =
        [{:port, port}, {:keyfile, ssl_keyfile}, {:certfile, ssl_certfile}]
        |> handle_ipv6_option(enable_ipv6)

      create_child_spec(:ranch_ssl, port, opts)
    end)
  end

  @spec create_child_spec(:ranch_tcp | :ranch_ssl, integer(), keyword()) :: Supervisor.child_spec()
  defp create_child_spec(transport, port, opts) do
    :ranch.child_spec({__MODULE__, port}, transport, opts, ElixIRCd.Server, [])
  end

  @spec handle_ipv6_option(keyword(), boolean()) :: keyword()
  defp handle_ipv6_option(opts, true), do: opts ++ [:inet6]
  defp handle_ipv6_option(opts, false), do: opts
end
