defmodule ElixIRCd.Server.Supervisor do
  @moduledoc """
  Supervisor for the SSL server.
  """

  use Supervisor

  require Logger

  import ElixIRCd.Utils, only: [logger_with_time: 3]

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
    Enum.map(server_listeners, &create_child_spec/1)
    |> Supervisor.init(strategy: :one_for_one)
  end

  @spec create_child_spec({:tcp | :ssl, keyword()}) :: Supervisor.child_spec()
  defp create_child_spec({transport, server_opts} = listener_opts) do
    logger_with_time(
      :info,
      "creating server listener at port #{Keyword.get(server_opts, :port)}#{if transport == :ssl, do: " (SSL)", else: ""}",
      fn ->
        :ranch.child_spec({__MODULE__, listener_opts}, convert_to_ranch(transport), server_opts, ElixIRCd.Server, [])
      end
    )
  end

  @spec convert_to_ranch(:tcp | :ssl) :: :ranch_tcp | :ranch_ssl
  defp convert_to_ranch(:tcp), do: :ranch_tcp
  defp convert_to_ranch(:ssl), do: :ranch_ssl
end
