defmodule ElixIRCd.Server.Supervisor do
  @moduledoc """
  Supervisor for the SSL server.
  """

  require Logger

  use Supervisor

  @doc """
  Starts the server supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_supervisor_opts) do
    server_listeners = Application.get_env(:elixircd, :server_listeners)
    Supervisor.start_link(__MODULE__, server_listeners, name: __MODULE__)
  end

  @impl true
  def init(server_listeners) do
    Enum.map(server_listeners, &create_child_spec/1)
    |> Supervisor.init(strategy: :one_for_one)
  end

  @spec create_child_spec({:ranch_tcp | :ranch_ssl, keyword()}) :: Supervisor.child_spec()
  defp create_child_spec({transport, server_opts} = listener_opts) do
    :ranch.child_spec({__MODULE__, listener_opts}, transport, server_opts, ElixIRCd.Server, [])
  end
end