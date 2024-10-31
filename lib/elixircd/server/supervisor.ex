defmodule ElixIRCd.Server.Supervisor do
  @moduledoc """
  Supervisor for the SSL server.
  """

  use Supervisor

  require Logger

  import ElixIRCd.Helper, only: [format_transport: 1]
  import ElixIRCd.Utils, only: [logger_with_time: 3]

  @type bandit_transport :: :ws | :wss
  @type ranch_transport :: :tcp | :ssl
  @type transport :: bandit_transport() | ranch_transport()

  @bandit_transports [:ws, :wss]
  @ranch_transports [:ssl, :tcp]

  @doc """
  Starts the server supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_supervisor_opts) do
    :persistent_term.put(:server_start_time, DateTime.utc_now())
    Supervisor.start_link(__MODULE__, Application.get_env(:elixircd, :listeners), name: __MODULE__)
  end

  @impl true
  def init(server_listeners) do
    server_listeners
    |> Enum.map(&build_child_spec/1)
    |> Supervisor.init(strategy: :one_for_one)
  end

  @spec build_child_spec({transport(), keyword()}) :: Supervisor.child_spec()
  defp build_child_spec({transport, server_opts} = listener_opts) do
    logger_with_time(
      :info,
      "creating #{format_transport(transport)} server listener at port #{Keyword.get(server_opts, :port)}",
      fn -> create_child_spec(listener_opts) end
    )
  end

  @spec create_child_spec({transport(), keyword()}) :: Supervisor.child_spec()
  defp create_child_spec({transport, server_opts}) when transport in @ranch_transports do
    :ranch.child_spec({__MODULE__, server_opts}, convert_to_ranch(transport), server_opts, ElixIRCd.Server, [])
  end

  defp create_child_spec({transport, server_opts}) when transport in @bandit_transports do
    scheme = if transport == :ws, do: :http, else: :https

    options =
      server_opts
      |> Keyword.put(:plug, ElixIRCd.Server.WsPlug)
      |> Keyword.put(:otp_app, :elixircd)
      |> Keyword.put_new(:scheme, scheme)

    {Bandit, options}
  end

  @spec convert_to_ranch(ranch_transport()) :: :ranch_tcp | :ranch_ssl
  defp convert_to_ranch(:tcp), do: :ranch_tcp
  defp convert_to_ranch(:ssl), do: :ranch_ssl
end
