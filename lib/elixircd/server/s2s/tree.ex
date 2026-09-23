defmodule ElixIRCd.Server.S2S.Tree do
  @moduledoc """
  Pure configured-tree topology and routing helpers for ENP/1.

  The static roster is the authority for possible edges. Active boots and edge
  readiness are runtime facts layered on top of it; this module never invents
  a parent, failover edge or mesh route.
  """

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Profile

  @max_nodes 256

  @type roster_row :: %{sid: String.t(), name: String.t(), parent: String.t() | nil}
  @type topology_node :: %{sid: String.t(), boot: Identity.id(), name: String.t(), description: term()}
  @type edge :: %{id: String.t(), a: map(), b: map(), ready_sides: [String.t()]}

  @doc "Normalizes and validates a configured roster without changing its meaning."
  @spec normalize_roster(term()) :: {:ok, [roster_row()]} | {:error, [term()]}
  def normalize_roster(roster), do: Profile.validate_roster(roster)

  @doc "Returns the root SID of a validated roster."
  @spec root([roster_row()]) :: {:ok, String.t()} | {:error, term()}
  def root(roster) when is_list(roster) do
    case Enum.filter(roster, &is_nil(&1.parent)) do
      [%{sid: sid}] -> {:ok, sid}
      _ -> {:error, :invalid_root}
    end
  end

  @doc "Returns the configured parent of a SID."
  @spec parent([roster_row()], String.t()) :: {:ok, String.t() | nil} | {:error, :unknown_sid}
  def parent(roster, sid) do
    case Enum.find(roster, &(&1.sid == sid)) do
      nil -> {:error, :unknown_sid}
      row -> {:ok, row.parent}
    end
  end

  @doc "Returns configured child SIDs in deterministic order."
  @spec children([roster_row()], String.t()) :: [String.t()]
  def children(roster, sid), do: roster |> Enum.filter(&(&1.parent == sid)) |> Enum.map(& &1.sid) |> Enum.sort()

  @doc "Returns the configured direct neighbors of a SID."
  @spec neighbors([roster_row()], String.t()) :: [String.t()]
  def neighbors(roster, sid) do
    parent_sid =
      case parent(roster, sid) do
        {:ok, value} -> value
        _ -> nil
      end

    Enum.uniq([parent_sid | children(roster, sid)]) |> Enum.reject(&is_nil/1) |> Enum.sort()
  end

  @doc "Checks that only a configured child may initiate the direct connection."
  @spec initiator_allowed?([roster_row()], String.t(), String.t()) :: boolean()
  def initiator_allowed?(roster, child_sid, parent_sid), do: parent(roster, child_sid) == {:ok, parent_sid}

  @doc "Returns the unique configured path between two SIDs."
  @spec path([roster_row()], String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def path(roster, from, to) do
    with :ok <- known?(roster, from),
         :ok <- known?(roster, to),
         {:ok, from_ancestors} <- ancestors(roster, from),
         {:ok, to_ancestors} <- ancestors(roster, to) do
      from_set = MapSet.new(from_ancestors)
      lca = Enum.find(to_ancestors, &MapSet.member?(from_set, &1))

      if lca do
        left = Enum.take_while(from_ancestors, &(&1 != lca))
        right = Enum.take_while(to_ancestors, &(&1 != lca)) |> Enum.reverse()
        {:ok, left ++ [lca] ++ right}
      else
        {:error, :disconnected_roster}
      end
    end
  end

  @doc "Returns the next configured hop from a local SID to a target SID."
  @spec next_hop([roster_row()], String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def next_hop(_roster, from, to) when from == to, do: {:ok, from}

  def next_hop(roster, from, to) do
    with {:ok, route} <- path(roster, from, to), [_local, next | _] <- route do
      {:ok, next}
    else
      [] -> {:error, :empty_route}
      {:error, _} = error -> error
    end
  end

  @doc "Filters a route using active-ready undirected edge pairs."
  @spec active_route([roster_row()], String.t(), String.t(), MapSet.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def active_route(roster, from, to, active_edges) do
    with {:ok, route} <- path(roster, from, to), :ok <- edges_ready?(route, active_edges) do
      {:ok, route}
    end
  end

  @doc "Builds a topology row for an exported connected component."
  @spec topology_row([roster_row()], map(), [map()], String.t()) :: map()
  def topology_row(roster, boots, active_edges, description \\ "") do
    nodes =
      roster
      |> Enum.map(fn %{sid: sid, name: name} ->
        %{"sid" => sid, "boot" => Map.fetch!(boots, sid), "name" => name, "description" => description}
      end)
      |> Enum.sort_by(& &1["sid"])

    edges =
      active_edges
      |> Enum.map(&normalize_edge(&1, boots))
      |> Enum.sort_by(& &1["id"])

    %{"kind" => "topology.add", "nodes" => nodes, "edges" => edges}
  end

  @doc "Validates a received topology row against the static roster and known boots."
  @spec validate_topology(map(), [roster_row()], map(), String.t(), keyword()) :: :ok | {:error, term()}
  def validate_topology(row, roster, known_boots, incoming_sid, options \\ []) when is_map(row) do
    roster_by_sid = Map.new(roster, &{&1.sid, &1})
    nodes = row["nodes"] || []
    edges = row["edges"] || []
    node_map = Map.new(nodes, &{&1["sid"], &1})

    with true <- length(nodes) <= @max_nodes,
         :ok <- validate_nodes(nodes, roster_by_sid, known_boots),
         :ok <- validate_edges(edges, roster_by_sid, known_boots, node_map),
         true <- connected_to?(nodes, edges, incoming_sid, Keyword.get(options, :require_incoming, true)),
         true <- edge_count_is_tree?(nodes, edges) do
      :ok
    else
      false -> {:error, :topology_not_connected}
      {:error, _} = error -> error
    end
  end

  defp known?(roster, sid), do: if(Enum.any?(roster, &(&1.sid == sid)), do: :ok, else: {:error, :unknown_sid})

  defp ancestors(roster, sid), do: ancestors(roster, sid, MapSet.new(), [])

  defp ancestors(_roster, nil, _seen, acc), do: {:ok, acc}

  defp ancestors(roster, sid, seen, acc) do
    if MapSet.member?(seen, sid) do
      {:error, :roster_cycle}
    else
      case parent(roster, sid) do
        {:ok, parent_sid} -> ancestors(roster, parent_sid, MapSet.put(seen, sid), acc ++ [sid])
        {:error, _} = error -> error
      end
    end
  end

  defp edges_ready?([_single], _active_edges), do: :ok

  defp edges_ready?(route, active_edges) do
    route
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [left, right] -> MapSet.member?(active_edges, edge_key(left, right)) end)
    |> case do
      true -> :ok
      false -> {:error, :inactive_route}
    end
  end

  defp edge_key(left, right), do: {min(left, right), max(left, right)}

  defp normalize_edge(%{"id" => id, "a" => a, "b" => b, "ready_sides" => ready}, _boots),
    do: %{"id" => id, "a" => a, "b" => b, "ready_sides" => Enum.sort(ready)}

  defp normalize_edge(%{id: id, a: a, b: b, ready_sides: ready}, _boots),
    do: %{"id" => id, "a" => a, "b" => b, "ready_sides" => Enum.sort(ready)}

  defp normalize_edge({left, right, id, ready}, boots) do
    endpoints = Enum.sort([left, right])
    [a_sid, b_sid] = endpoints

    %{
      "id" => id,
      "a" => %{"sid" => a_sid, "boot" => Map.fetch!(boots, a_sid)},
      "b" => %{"sid" => b_sid, "boot" => Map.fetch!(boots, b_sid)},
      "ready_sides" => Enum.sort(ready)
    }
  end

  defp validate_nodes(nodes, roster, known_boots) do
    sids = Enum.map(nodes, & &1["sid"])

    cond do
      length(sids) != length(Enum.uniq(sids)) -> {:error, :duplicate_topology_sid}
      Enum.any?(nodes, fn node -> not node_matches?(node, roster, known_boots) end) -> {:error, :invalid_topology_node}
      true -> :ok
    end
  end

  defp node_matches?(%{"sid" => sid, "boot" => boot}, roster, known_boots) do
    Map.has_key?(roster, sid) and Identity.valid_id?(boot) and
      (not Map.has_key?(known_boots, sid) or Identity.secure_equal?(Map.fetch!(known_boots, sid), boot))
  end

  defp node_matches?(_node, _roster, _known_boots), do: false

  defp validate_edges(edges, roster, known_boots, nodes) do
    pairs = Enum.map(edges, fn edge -> Enum.sort([edge["a"]["sid"], edge["b"]["sid"]]) end)

    if length(pairs) != length(Enum.uniq(pairs)) do
      {:error, :duplicate_topology_edge}
    else
      Enum.reduce_while(edges, :ok, fn edge, :ok ->
        case valid_edge?(edge, roster, known_boots, nodes) do
          true -> {:cont, :ok}
          false -> {:halt, {:error, :invalid_topology_edge}}
        end
      end)
    end
  end

  defp valid_edge?(
         %{"id" => id, "a" => %{"sid" => left} = a, "b" => %{"sid" => right} = b, "ready_sides" => ready},
         roster,
         known_boots,
         nodes
       ) do
    left != right and Map.has_key?(roster, left) and Map.has_key?(roster, right) and
      Map.has_key?(nodes, left) and Map.has_key?(nodes, right) and
      node_matches?(a, roster, known_boots) and node_matches?(b, roster, known_boots) and
      valid_hex?(id, 64) and
      Enum.all?(ready, &(&1 in [left, right])) and
      (parent(Map.values(roster), left) == {:ok, right} or parent(Map.values(roster), right) == {:ok, left})
  end

  defp valid_edge?(_edge, _roster, _known_boots, _nodes), do: false

  defp connected_to?(nodes, edges, incoming_sid, require_incoming?) do
    node_sids = MapSet.new(Enum.map(nodes, & &1["sid"]))

    (not require_incoming? or incoming_sid in node_sids) and
      Enum.all?(edges, fn edge -> edge["a"]["sid"] in node_sids and edge["b"]["sid"] in node_sids end) and
      connected_component?(node_sids, edges, incoming_sid, require_incoming?)
  end

  defp connected_component?(node_sids, edges, incoming_sid, true),
    do: MapSet.equal?(reachable_nodes(incoming_sid, edges, MapSet.new([incoming_sid])), node_sids)

  defp connected_component?(node_sids, edges, _incoming_sid, false) do
    case MapSet.to_list(node_sids) do
      [] -> false
      [sid | _] -> MapSet.equal?(reachable_nodes(sid, edges, MapSet.new([sid])), node_sids)
    end
  end

  defp edge_count_is_tree?([_node], []), do: true
  defp edge_count_is_tree?(nodes, edges), do: length(edges) == length(nodes) - 1

  defp reachable_nodes(sid, edges, visited) do
    next =
      edges
      |> Enum.flat_map(fn edge ->
        cond do
          edge["a"]["sid"] == sid -> [edge["b"]["sid"]]
          edge["b"]["sid"] == sid -> [edge["a"]["sid"]]
          true -> []
        end
      end)
      |> Enum.reject(&MapSet.member?(visited, &1))

    Enum.reduce(next, visited, fn neighbor, current ->
      reachable_nodes(neighbor, edges, MapSet.put(current, neighbor))
    end)
  end

  defp valid_hex?(value, length) when is_binary(value),
    do: byte_size(value) == length and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp valid_hex?(_value, _length), do: false
end
