defmodule ElixIRCd.Server.Supervisor do
  @moduledoc """
  Supervisor for the SSL server.
  """

  use Supervisor

  require Logger

  @doc """
  Starts the server supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_supervisor_opts) do
    Application.put_env(:elixircd, :server_start_time, DateTime.utc_now())
    Supervisor.start_link(__MODULE__, Application.get_env(:elixircd, :listeners), name: __MODULE__)
  end

  @impl true
  def init(server_listeners) do
    Enum.map(server_listeners, &create_child_spec/1)
    |> Supervisor.init(strategy: :one_for_one)
  end

  @spec create_child_spec({:tcp | :ssl, keyword()}) :: Supervisor.child_spec()
  defp create_child_spec({transport, server_opts} = listener_opts) do
    :ranch.child_spec({__MODULE__, listener_opts}, convert_to_ranch(transport), server_opts, ElixIRCd.Server, [])
  end

  @spec convert_to_ranch(:tcp | :ssl) :: :ranch_tcp | :ranch_ssl
  defp convert_to_ranch(:tcp), do: :ranch_tcp
  defp convert_to_ranch(:ssl), do: :ranch_ssl
end
