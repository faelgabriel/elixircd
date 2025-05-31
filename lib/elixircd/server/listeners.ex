defmodule ElixIRCd.Server.Listeners do
  @moduledoc """
  Module for handling IRC server listeners.
  """

  use Supervisor

  require Logger

  import ElixIRCd.Utils.System, only: [logger_with_time: 3]

  @type scheme_tcp_transport :: :tcp | :tls
  @type scheme_http_transport :: :http | :https
  @type scheme_transport :: scheme_tcp_transport() | scheme_http_transport()

  @doc """
  Starts the server supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_opts) do
    :persistent_term.put(:server_start_time, DateTime.utc_now())
    Supervisor.start_link(__MODULE__, Application.get_env(:elixircd, :listeners), name: __MODULE__)
  end

  @impl true
  def init(server_listeners) do
    server_listeners
    |> Enum.map(&build_child_spec/1)
    |> Supervisor.init(strategy: :one_for_one)
  end

  @spec build_child_spec({scheme_transport(), keyword()}) :: Supervisor.child_spec()
  defp build_child_spec({scheme_transport, server_opts} = listener_opts) do
    logger_with_time(
      :info,
      "creating #{scheme_transport} listener at port #{Keyword.get(server_opts, :port)}",
      fn -> create_child_spec(listener_opts) end
    )
  end

  @spec create_child_spec({scheme_transport(), keyword()}) :: {module(), keyword()}
  defp create_child_spec({scheme_transport, server_opts}) when scheme_transport in [:tcp, :tls] do
    transport_module =
      if scheme_transport == :tls, do: ThousandIsland.Transports.SSL, else: ThousandIsland.Transports.TCP

    options =
      server_opts
      |> Keyword.put_new(:handler_module, ElixIRCd.Server.TcpListener)
      |> Keyword.put_new(:transport_module, transport_module)

    {ThousandIsland, options}
  end

  defp create_child_spec({scheme_transport, server_opts}) when scheme_transport in [:http, :https] do
    options =
      server_opts
      |> Keyword.put_new(:plug, ElixIRCd.Server.HttpPlug)
      |> Keyword.put_new(:otp_app, :elixircd)
      |> Keyword.put_new(:scheme, scheme_transport)
      |> Keyword.put_new(:startup_log, false)

    {Bandit, options}
  end
end
