defmodule ElixIRCd.Server.S2S do
  @moduledoc """
  Supervision boundary for the native ENP/1 federation.

  The complete tree, its manager and its dedicated mutual-TLS listener are
  absent when the feature is disabled. No client listener is repurposed.
  """

  use Supervisor

  alias ElixIRCd.Server.S2S.TLS

  @manager ElixIRCd.Server.S2S.Manager

  @doc "Starts the native ENP/1 supervision boundary when S2S is enabled."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(options) do
    config = Keyword.get(options, :config, Application.get_all_env(:elixircd))
    s2s = section(config, :s2s)

    if value(s2s, :enabled, false) do
      listener =
        TLS.listener_options(s2s)
        |> Keyword.merge(
          handler_module: ElixIRCd.Server.S2S.Listener,
          handler_options: %{manager: @manager, config: config},
          num_acceptors: 4,
          num_connections: max_connections_per_acceptor(s2s),
          read_timeout: :infinity,
          shutdown_timeout: value(section(s2s, :timeouts), :snapshot_ms, 120_000),
          supervisor_options: [name: ElixIRCd.Server.S2S.ListenerSupervisor]
        )

      children = [
        {DynamicSupervisor, strategy: :one_for_one, name: ElixIRCd.Server.S2S.ConnectorSupervisor},
        {@manager, config: config, name: @manager},
        {ThousandIsland, listener}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    else
      :ignore
    end
  end

  defp section(config, key) when is_map(config), do: Map.get(config, key, Map.get(config, Atom.to_string(key), %{}))
  defp section(config, key) when is_list(config), do: Keyword.get(config, key, [])
  defp section(_config, _key), do: []

  defp value(section, key, default) when is_map(section),
    do: Map.get(section, key, Map.get(section, Atom.to_string(key), default))

  defp value(section, key, default) when is_list(section), do: Keyword.get(section, key, default)
  defp value(_section, _key, default), do: default

  defp max_connections_per_acceptor(s2s) do
    s2s
    |> section(:budgets)
    |> value(:max_connections_per_acceptor, 256)
  end
end
