defmodule ElixIRCd.Server.Listeners do
  @moduledoc """
  Module for handling IRC server listeners.
  """

  use Supervisor

  import ElixIRCd.Utils.System, only: [logger_with_time: 3]

  alias ElixIRCd.Server.Connection

  @type scheme_tcp_transport :: :tcp | :tls
  @type scheme_http_transport :: :http | :https
  @type scheme_transport :: scheme_tcp_transport() | scheme_http_transport()

  @doc """
  Starts the server supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_opts) do
    :persistent_term.put(:server_start_time, DateTime.utc_now())
    Supervisor.start_link(__MODULE__, Application.fetch_env!(:elixircd, :listeners), name: __MODULE__)
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
      |> Keyword.put(:handler_module, ElixIRCd.Server.TcpListener)
      |> Keyword.put(:transport_module, transport_module)

    {ThousandIsland, options}
  end

  defp create_child_spec({scheme_transport, server_opts}) when scheme_transport in [:http, :https] do
    websocket_options =
      server_opts
      |> Keyword.fetch!(:websocket_options)
      |> Keyword.put(:max_fragmented_message_size, Connection.max_wire_length())

    options =
      server_opts
      |> route_tls_options()
      |> Keyword.put(:plug, ElixIRCd.Server.HttpPlug)
      |> Keyword.put(:otp_app, :elixircd)
      |> Keyword.put(:scheme, scheme_transport)
      |> Keyword.put(:websocket_options, websocket_options)

    {Bandit, options}
  end

  @spec route_tls_options(keyword()) :: keyword()
  defp route_tls_options(opts) do
    {tls, opts} = Keyword.split(opts, [:cacertfile, :versions])

    if tls == [] do
      opts
    else
      Keyword.update(
        opts,
        :thousand_island_options,
        [transport_options: tls],
        &Keyword.put(&1, :transport_options, tls)
      )
    end
  end
end
