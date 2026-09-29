defmodule ElixIRCd.ServerLink.Supervisor do
  @moduledoc "Starts the separate server-link transport only when configured."

  use Supervisor

  @doc "Starts the opt-in server-link supervision tree."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, Application.fetch_env!(:elixircd, :server_links), name: __MODULE__)
  end

  @impl true
  def init(config) do
    children =
      if config[:enabled] do
        [
          {ElixIRCd.ServerLink.Projector, []},
          {ElixIRCd.ServerLink.Hub, Keyword.put(config, :projector, ElixIRCd.ServerLink.Projector)}
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
