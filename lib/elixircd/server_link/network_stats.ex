defmodule ElixIRCd.ServerLink.NetworkStats do
  @moduledoc "Committed network counts published by the link coordinator for local IRC transactions."

  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.Route

  @table :elixircd_server_link_network_stats
  @key :snapshot

  @enforce_keys [:remote_visible, :remote_invisible, :remote_operators, :remote_servers, :direct_servers, :channels]
  defstruct [:remote_visible, :remote_invisible, :remote_operators, :remote_servers, :direct_servers, :channels]

  @type t :: %__MODULE__{
          remote_visible: non_neg_integer(),
          remote_invisible: non_neg_integer(),
          remote_operators: non_neg_integer(),
          remote_servers: non_neg_integer(),
          direct_servers: non_neg_integer(),
          channels: non_neg_integer()
        }

  @doc "Creates the coordinator-owned read view for network user and server counts."
  @spec create() :: :ets.tid()
  def create, do: :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])

  @doc "Describes a standalone server using its local channel count."
  @spec standalone(non_neg_integer()) :: t()
  def standalone(channels) do
    %__MODULE__{
      remote_visible: 0,
      remote_invisible: 0,
      remote_operators: 0,
      remote_servers: 0,
      direct_servers: 0,
      channels: channels
    }
  end

  @doc "Reads one atomic count snapshot without calling the coordinator inside Mnesia."
  @spec get() :: {:ok, t()} | :unavailable
  def get do
    if :ets.whereis(@table) != :undefined do
      case :ets.lookup(@table, @key) do
        [{@key, %__MODULE__{} = snapshot}] -> {:ok, snapshot}
        [] -> :unavailable
      end
    else
      :unavailable
    end
  rescue
    ArgumentError -> :unavailable
  end

  @doc "Publishes counts derived only from committed remote state and selected channels."
  @spec publish(:ets.tid() | nil, Replica.t(), %{optional(String.t()) => Route.t()}, map(), map()) :: :ok
  def publish(nil, _replica, _routes, _links, _channels), do: :ok

  def publish(table, %Replica{} = replica, routes, links, channels) do
    {visible, invisible, operators} =
      Enum.reduce(replica.users, {0, 0, 0}, fn {_identity, user}, {visible, invisible, operators} ->
        modes = user["modes"]
        visible = if "i" in modes, do: visible, else: visible + 1
        invisible = if "i" in modes, do: invisible + 1, else: invisible
        operators = if "o" in modes, do: operators + 1, else: operators
        {visible, invisible, operators}
      end)

    snapshot = %__MODULE__{
      remote_visible: visible,
      remote_invisible: invisible,
      remote_operators: operators,
      remote_servers: map_size(routes),
      direct_servers: map_size(links),
      channels: map_size(channels)
    }

    :ets.insert(table, {@key, snapshot})
    :ok
  end
end
