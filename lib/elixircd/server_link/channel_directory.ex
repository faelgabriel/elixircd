defmodule ElixIRCd.ServerLink.ChannelDirectory do
  @moduledoc "Read-only network channel authority index owned by the production link coordinator."

  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.Utils.CaseMapping

  @table :elixircd_server_link_channels

  @doc "Creates the channel index owned by the named coordinator."
  @spec create() :: :ets.tid()
  def create do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
  end

  @doc "Reads the current authority without calling the coordinator from an IRC transaction."
  @spec get(String.t()) :: {:ok, ChannelView.t()} | :error | :unavailable
  def get(name) do
    if :ets.whereis(@table) != :undefined do
      case :ets.lookup(@table, CaseMapping.normalize(name)) do
        [{_key, winner}] -> {:ok, winner}
        [] -> :error
      end
    else
      :unavailable
    end
  rescue
    ArgumentError -> :unavailable
  end

  @doc "Lists committed channel views for network-wide channel queries."
  @spec all() :: [ChannelView.t()] | :unavailable
  def all do
    if :ets.whereis(@table) != :undefined do
      :ets.tab2list(@table) |> Enum.map(&elem(&1, 1))
    else
      :unavailable
    end
  rescue
    ArgumentError -> :unavailable
  end

  @doc "Publishes changed winners after a local or remote channel state commit."
  @spec sync(:ets.tid() | nil, map(), map()) :: :ok
  def sync(nil, _old, _current), do: :ok

  def sync(table, old, current) do
    for {key, _winner} <- old, not Map.has_key?(current, key), do: :ets.delete(table, key)

    for {key, winner} <- current, Map.get(old, key) != winner do
      :ets.insert(table, {key, winner})
    end

    :ok
  end
end
