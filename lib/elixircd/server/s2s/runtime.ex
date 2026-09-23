defmodule ElixIRCd.Server.S2S.Runtime do
  @moduledoc """
  Pure network state boundary used by a native link manager.

  It applies one validated state frame to an immutable runtime projection.
  The caller can persist the resulting projection and drain the returned
  effects as one local commit group; a failed row never exposes intermediate
  state.
  """

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Policy
  alias ElixIRCd.Server.S2S.PolicyStore
  alias ElixIRCd.Server.S2S.Output
  alias ElixIRCd.Server.S2S.Schema
  alias ElixIRCd.Server.S2S.State
  alias ElixIRCd.Server.S2S.Tree
  alias ElixIRCd.Server.S2S.Projection
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelExcepts
  alias ElixIRCd.Repositories.ChannelInvexes
  alias ElixIRCd.Repositories.ChannelListTombstones
  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users

  @type t :: %{
          sid: String.t(),
          boot: Identity.id(),
          roster: [map()],
          case_mapping: atom(),
          nodes: map(),
          edges: map(),
          active_edges: MapSet.t(),
          reachable_sids: MapSet.t(),
          users: map(),
          memberships: map(),
          channels: map(),
          merge_contexts: MapSet.t(),
          policy: Policy.state(),
          policy_cache: map() | nil,
          services_authority: String.t() | nil
        }

  @doc "Creates a runtime projection from the validated application configuration."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(config) do
    s2s = section(config, :s2s)
    sid = value(s2s, :server_id, "")
    boot = value(s2s, :boot, Identity.boot())

    with true <- Identity.valid_sid?(sid),
         true <- Identity.valid_id?(boot),
         {:ok, roster} <- Tree.normalize_roster(value(s2s, :roster, [])),
         true <- Enum.any?(roster, &(&1.sid == sid)) do
      name = roster |> Enum.find(&(&1.sid == sid)) |> Map.fetch!(:name)
      policy_store = PolicyStore.read()
      configured_epoch = value(s2s, :policy_epoch, nil)
      epoch = configured_epoch || (policy_store && policy_store.epoch) || Identity.nonce()
      revision = (policy_store && policy_store.revision) || 0

      {:ok,
       %{
         sid: sid,
         boot: boot,
         roster: roster,
         case_mapping: value(section(config, :settings), :case_mapping, :rfc1459),
         nodes: %{sid => %{"sid" => sid, "boot" => boot, "name" => name, "description" => ""}},
         edges: %{},
         active_edges: MapSet.new(),
         reachable_sids: MapSet.new([sid]),
         users: %{},
         memberships: %{},
         channels: %{},
         merge_contexts: MapSet.new(),
         policy: Policy.new(epoch: epoch, revision: revision),
         policy_cache: nil,
         services_authority: value(s2s, :services_authority, nil)
       }}
    else
      false ->
        {:error, :invalid_runtime_identity}

      {:error, _} = error ->
        error
    end
  end

  @doc "Applies one complete state frame atomically to the runtime projection."
  @spec apply_frame(t(), map(), keyword()) :: {:ok, t(), [map()]} | {:error, term()}
  def apply_frame(runtime, frame, options \\ [])

  def apply_frame(
        runtime,
        %{"t" => "state", "origin" => origin, "context" => context, "changes" => changes} = frame,
        options
      ) do
    source_sid = Keyword.get(options, :source_sid, origin["sid"])
    snapshot? = Keyword.get(options, :snapshot, false)

    with :ok <- Schema.validate_frame(frame),
         :ok <- source_allowed?(runtime, origin, source_sid, snapshot?, changes),
         :ok <- merge_context_allowed?(runtime, context),
         {:ok, next, effects} <-
           apply_rows(runtime, changes, origin, context,
             source_sid: source_sid,
             snapshot: snapshot?
           ),
         {:ok, next} <- recompute_nicknames(next) do
      {:ok, next, effects}
    end
  end

  def apply_frame(_runtime, _frame, _options), do: {:error, :invalid_state_frame}

  @doc "Allows the authenticated parent route to carry a child edge readiness marker during bootstrap."
  @spec topology_bootstrap_origin_allowed?(t(), map(), String.t(), [map()]) :: boolean()
  def topology_bootstrap_origin_allowed?(runtime, origin, source_sid, changes)
      when is_map(runtime) and is_map(origin) and is_binary(source_sid) and is_list(changes) do
    topology_bootstrap_changes? =
      changes != [] and
        Enum.all?(changes, fn
          %{"kind" => "topology.ready", "edge_id" => edge_id, "side" => side} ->
            topology_ready_allowed?(runtime, origin, source_sid, edge_id, side)

          %{"kind" => "topology.add", "nodes" => nodes, "edges" => edges} ->
            topology_add_allowed?(runtime, origin, source_sid, nodes, edges)

          _ ->
            false
        end)

    topology_bootstrap_changes?
  end

  def topology_bootstrap_origin_allowed?(_runtime, _origin, _source_sid, _changes), do: false

  @doc "Adds a peer boot learned from an authenticated TLS hello."
  @spec learn_node(t(), map()) :: {:ok, t()} | {:error, term()}
  def learn_node(runtime, %{"sid" => sid, "boot" => boot, "name" => name} = node)
      when is_binary(sid) and is_binary(name) do
    if Identity.valid_sid?(sid) and Identity.valid_id?(boot) and Enum.any?(runtime.roster, &(&1.sid == sid)) do
      case runtime.nodes[sid] do
        nil ->
          {:ok, %{runtime | nodes: Map.put(runtime.nodes, sid, Map.take(node, ["sid", "boot", "name", "description"]))}}

        %{"boot" => ^boot} ->
          {:ok, runtime}

        _ ->
          {:error, :duplicate_live_boot}
      end
    else
      {:error, :invalid_topology_node}
    end
  end

  def learn_node(_runtime, _node), do: {:error, :invalid_topology_node}

  @doc "Applies a complete snapshot page set atomically after digest verification."
  @spec apply_snapshot_rows(t(), [map()], map(), map(), keyword()) ::
          {:ok, t(), [map()]} | {:error, term()}
  def apply_snapshot_rows(runtime, rows, origin, context \\ %{"kind" => "live"}, options \\ [])

  def apply_snapshot_rows(runtime, rows, origin, context, options)
      when is_list(rows) and is_map(origin) and is_map(context) do
    source_sid = Keyword.get(options, :source_sid, origin["sid"])

    with true <- length(rows) <= 65_536,
         :ok <- source_allowed?(runtime, origin, source_sid, true, []),
         :ok <- merge_context_allowed?(runtime, context),
         true <- all_rows_valid?(rows),
         {:ok, prepared} <- prepare_snapshot(runtime, rows, options),
         {:ok, next, effects} <-
           apply_rows(prepared, rows, origin, context, snapshot: true, source_sid: source_sid),
         {:ok, next} <- recompute_nicknames(next) do
      {:ok, next, effects}
    else
      false -> {:error, :snapshot_rows_too_large}
      {:error, _} = error -> error
    end
  end

  def apply_snapshot_rows(_runtime, _rows, _origin, _context, _options), do: {:error, :invalid_snapshot_rows}

  @doc "Loads the existing local C2S tables into the explicit network projection."
  @spec bootstrap(t()) :: {:ok, t()} | {:error, term()}
  def bootstrap(runtime) do
    Memento.transaction!(fn ->
      channels = Channels.get_all() |> Enum.reject(&String.starts_with?(&1.name, "&"))

      channel_refs =
        Map.new(channels, fn channel ->
          {channel.name_key,
           %{
             "name" => channel.name,
             "born_ms" => max(channel.born_ms || 1, 1),
             "cid" => channel.cid
           }}
        end)

      with {:ok, runtime, statuses} <- bootstrap_users(runtime, channel_refs),
           {:ok, runtime} <- bootstrap_channels(runtime, channels),
           {:ok, runtime} <- apply_bootstrap_rows(runtime, statuses),
           {:ok, runtime} <- bootstrap_policy(runtime) do
        {:ok, runtime}
      end
    end)
  rescue
    error -> {:error, {:bootstrap_failed, Exception.message(error)}}
  end

  @doc "Adds one local committed row and returns the updated projection."
  @spec apply_local_row(t(), map(), keyword()) :: {:ok, t(), [map()]} | {:error, term()}
  def apply_local_row(runtime, row, options \\ []) do
    origin = %{"sid" => runtime.sid, "boot" => runtime.boot}
    context = %{"kind" => "live"}

    with :ok <- Schema.validate_row(row),
         {:ok, next, effects} <- apply_row(runtime, row, origin, context, options),
         {:ok, next} <- recompute_nicknames(next) do
      {:ok, next, effects}
    end
  end

  @doc "Applies a bounded local publication group atomically to the projection."
  @spec apply_local_rows(t(), [map()], keyword()) :: {:ok, t(), [map()]} | {:error, term()}
  def apply_local_rows(runtime, rows, options \\ [])

  def apply_local_rows(runtime, rows, options) when is_list(rows) and length(rows) <= 256 do
    Enum.reduce_while(rows, {:ok, runtime, []}, fn row, {:ok, current, effects} ->
      case apply_local_row(current, row, options) do
        {:ok, next, row_effects} -> {:cont, {:ok, next, effects ++ row_effects}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def apply_local_rows(_runtime, _rows, _options), do: {:error, :publication_group_too_large}

  @doc "Returns explicit rows suitable for a network snapshot."
  @spec export_projections(t()) :: map()
  def export_projections(runtime) do
    topology = [
      %{
        "kind" => "topology.add",
        "nodes" =>
          runtime.nodes
          |> Map.values()
          |> Enum.map(&topology_node(runtime, &1))
          |> Enum.sort_by(& &1["sid"]),
        "edges" =>
          runtime.edges
          |> Map.values()
          |> Enum.sort_by(& &1.id)
          |> Enum.map(fn edge ->
            %{"id" => edge.id, "a" => edge.a, "b" => edge.b, "ready_sides" => edge.ready_sides}
          end)
      }
    ]

    users =
      runtime.users
      |> Map.values()
      |> Enum.sort_by(& &1["uid"])
      |> Enum.map(&%{"kind" => "user.put", "user" => Map.delete(&1, "effective_nick")})

    channels =
      runtime.channels
      |> Map.values()
      |> Enum.reject(&String.starts_with?(&1.ref["name"], "&"))
      |> Enum.sort_by(& &1.ref["name"])
      |> Enum.flat_map(fn channel ->
        [%{"kind" => "channel.ensure", "channel" => channel.ref} | channel_rows(channel, runtime.sid)]
      end)

    memberships =
      runtime.memberships
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {uid, membership} ->
        %{
          "kind" => "memberships.put",
          "uid" => uid,
          "home" => membership.home,
          "rev" => membership.rev,
          "entries" => membership.entries,
          "cause" => %{
            "action" => "sync",
            "channel" => nil,
            "join_id" => nil,
            "by" => %{"server" => runtime.sid},
            "reason" => "snapshot"
          }
        }
      end)

    status =
      runtime.channels
      |> Map.values()
      |> Enum.flat_map(&status_rows/1)
      |> Enum.sort_by(fn row -> {row["channel"]["name"], row["uid"], row["join_id"], row["mode"]} end)

    policy =
      if Policy.grant_ready?(runtime.policy) and runtime.services_authority == runtime.sid do
        case Policy.image_payloads(runtime.policy, 256) do
          {:ok, payloads} -> policy_rows(payloads, runtime.policy)
          {:error, _} -> []
        end
      else
        []
      end

    %{
      topology: topology,
      policy: policy,
      users: users,
      channels: channels,
      memberships: memberships,
      status: status,
      markers: []
    }
  end

  defp all_rows_valid?(rows), do: Enum.all?(rows, &(Schema.validate_row(&1) == :ok))

  defp topology_node(runtime, node) when is_map(node) do
    configured_name =
      Enum.find_value(runtime.roster, node["name"] || "", fn row ->
        if row.sid == node["sid"], do: row.name
      end)

    node
    |> Map.put("name", configured_name)
    |> Map.put("description", node["description"] || "")
  end

  defp prepare_snapshot(runtime, rows, options) do
    topology = Enum.find(rows, &(&1["kind"] == "topology.add"))

    if is_nil(topology),
      do: {:ok, runtime},
      else: prepare_complete_snapshot(runtime, rows, topology, options)
  end

  defp prepare_complete_snapshot(runtime, rows, topology, options) do
    user_rows = Enum.filter(rows, &(&1["kind"] == "user.put"))
    channel_rows = Enum.filter(rows, &(&1["kind"] == "channel.ensure"))

    with :ok <- snapshot_has_local_node?(runtime, topology) do
      visible_sids =
        topology
        |> case do
          %{"nodes" => nodes} -> MapSet.new(Enum.map(nodes, & &1["sid"]))
          _ -> MapSet.new()
        end

      visible_users = MapSet.new(Enum.map(user_rows, &get_in(&1, ["user", "uid"])))

      users =
        runtime.users
        |> Enum.reject(fn {uid, user} ->
          MapSet.member?(visible_sids, get_in(user, ["home", "sid"])) and
            not MapSet.member?(visible_users, uid)
        end)
        |> Map.new()

      memberships = Map.take(runtime.memberships, Map.keys(users))
      channel_names = MapSet.new(Enum.map(channel_rows, &get_in(&1, ["channel", "name"])))

      channels =
        runtime.channels
        |> Enum.reject(fn {_key, channel} ->
          name = channel.ref["name"]
          not String.starts_with?(name, "&") and not MapSet.member?(channel_names, name)
        end)
        |> Map.new()
        |> drop_statuses_for_missing_users(users)

      prepared = %{runtime | users: users, memberships: memberships, channels: channels, policy_cache: nil}

      {:ok,
       install_snapshot_topology(prepared, topology,
         preserve_local_edges: Keyword.get(options, :preserve_local_edges, false)
       )}
    end
  end

  defp snapshot_has_local_node?(_runtime, nil), do: :ok

  defp snapshot_has_local_node?(runtime, %{"nodes" => nodes}) do
    if Enum.any?(nodes, &(&1["sid"] == runtime.sid)), do: :ok, else: {:error, :snapshot_missing_local_node}
  end

  defp snapshot_has_local_node?(_runtime, _topology), do: {:error, :invalid_snapshot_topology}

  defp install_snapshot_topology(runtime, %{"nodes" => nodes, "edges" => edges}, options) do
    node_map = Map.new(nodes, &{&1["sid"], &1})

    snapshot_edges =
      Map.new(edges, fn edge ->
        {edge["id"],
         %{
           id: edge["id"],
           a: edge["a"],
           b: edge["b"],
           ready_sides: edge["ready_sides"]
         }}
      end)

    {node_map, edge_map} =
      if Keyword.get(options, :preserve_local_edges, false) do
        # A snapshot received over one physical edge describes the sender's
        # current component. It cannot describe a sibling branch that is
        # reachable from the receiver through another edge. Keep that
        # already-known topology and merge the sender's view into it; explicit
        # topology.remove rows remain responsible for deleting stale edges.
        merged_edges =
          Enum.reduce(runtime.edges, snapshot_edges, fn {id, local_edge}, acc ->
            Map.update(acc, id, local_edge, &merge_snapshot_edge(&1, local_edge))
          end)

        {Map.merge(runtime.nodes, node_map), merged_edges}
      else
        {node_map, snapshot_edges}
      end

    %{runtime | nodes: node_map, edges: edge_map}
    |> refresh_reachability()
  end

  defp merge_snapshot_edge(snapshot_edge, local_edge) do
    %{snapshot_edge | ready_sides: Enum.uniq(snapshot_edge.ready_sides ++ local_edge.ready_sides) |> Enum.sort()}
  end

  defp drop_statuses_for_missing_users(channels, users) do
    Map.new(channels, fn {key, channel} ->
      statuses =
        channel.statuses
        |> Enum.filter(fn {{uid, _join_id, _mode}, _register} -> Map.has_key?(users, uid) end)
        |> Map.new()

      {key, %{channel | statuses: statuses}}
    end)
  end

  defp bootstrap_users(runtime, channel_refs) do
    Users.get_all()
    |> Enum.filter(&(&1.registered == true))
    |> Enum.reduce_while({:ok, runtime, []}, fn user, {:ok, current, all_statuses} ->
      with {:ok, projection} <-
             Projection.user(user, current.boot,
               sid: current.sid,
               policy_epoch: current.policy.epoch,
               policy: current.policy
             ),
           {:ok, next, _} <-
             apply_local_row(current, %{"kind" => "user.put", "user" => projection}, policy_epoch: current.policy.epoch),
           records <- if(is_pid(user.pid), do: UserChannels.get_by_user_pid(user.pid), else: []),
           {:ok, _membership, user_statuses} <-
             Projection.memberships(user, records, current.sid, current.boot,
               sid: current.sid,
               channel_refs: channel_refs,
               status_stamp: Output.next_stamp(current.sid, current.boot)
             ),
           membership <- membership_row(user, projection, records, current, channel_refs) do
        case apply_bootstrap_rows(next, [membership]) do
          {:ok, next} -> {:cont, {:ok, next, all_statuses ++ user_statuses}}
          {:error, _} = error -> {:halt, error}
        end
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp bootstrap_channels(runtime, channels) do
    Enum.reduce_while(channels, {:ok, runtime}, fn channel, {:ok, current} ->
      list_rows = bootstrap_channel_lists(channel.name_key, channel_ref(channel), current)

      case Projection.channel(channel, current.sid, current.boot,
             stamp: Output.next_stamp(current.sid, current.boot),
             list_rows: list_rows
           ) do
        {:ok, rows} ->
          case apply_bootstrap_rows(current, rows) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, _} = error -> {:halt, error}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp bootstrap_policy(%{services_authority: authority, sid: sid} = runtime)
       when is_binary(authority) and authority == sid,
       do: load_policy_sources(runtime)

  defp bootstrap_policy(runtime), do: {:ok, runtime}

  defp load_policy_sources(runtime) do
    nicks = RegisteredNicks.get_all()
    channels = RegisteredChannels.get_all()
    access = RegisteredChannelAccesses.get_all()

    case Policy.from_sources(runtime.policy.epoch, nicks, channels, access, [],
           revision: max(runtime.policy.revision, 1)
         ) do
      {:ok, policy} ->
        _ = PolicyStore.persist_revision(policy.epoch, policy.revision)
        {:ok, %{runtime | policy: policy}}

      {:error, _} = error ->
        error
    end
  rescue
    error -> {:error, {:policy_bootstrap_failed, Exception.message(error)}}
  end

  defp bootstrap_channel_lists(name_key, ref, runtime) do
    live_rows =
      [
        {"b", ChannelBans.get_by_channel_name_key(name_key)},
        {"e", ChannelExcepts.get_by_channel_name_key(name_key)},
        {"I", ChannelInvexes.get_by_channel_name_key(name_key)}
      ]
      |> Enum.flat_map(fn {mode, records} ->
        Enum.map(records, fn record ->
          {record, stamp} = ensure_live_list_stamp(record, runtime)
          set_ms = max(DateTime.to_unix(record.created_at, :millisecond), 1)

          %{
            "kind" => "channel.list",
            "channel" => ref,
            "mode" => mode,
            "mask" => record.mask,
            "present" => true,
            "set_by" => record.setter,
            "set_ms" => set_ms,
            "stamp" => stamp
          }
        end)
      end)

    tombstone_rows =
      Enum.map(ChannelListTombstones.get_by_channel_name_key(name_key), fn tombstone ->
        {tombstone, stamp} = ensure_tombstone_stamp(tombstone, runtime)

        %{
          "kind" => "channel.list",
          "channel" => ref,
          "mode" => tombstone.mode,
          "mask" => tombstone.mask,
          "present" => false,
          "set_by" => tombstone.set_by,
          "set_ms" => tombstone.set_ms,
          "stamp" => stamp
        }
      end)

    live_rows ++ tombstone_rows
  rescue
    _ -> []
  end

  defp apply_bootstrap_rows(runtime, rows) do
    Enum.reduce_while(rows, {:ok, runtime}, fn row, {:ok, current} ->
      case apply_local_row(current, row) do
        {:ok, next, _} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_live_list_stamp(%{stamp: stamp} = record, _runtime) when is_list(stamp), do: {record, stamp}

  defp ensure_live_list_stamp(record, runtime) do
    stamp = Output.next_stamp(runtime.sid, runtime.boot)
    _ = Memento.Query.write(%{record | stamp: stamp})
    {%{record | stamp: stamp}, stamp}
  end

  defp ensure_tombstone_stamp(%{stamp: stamp} = tombstone, _runtime) when is_list(stamp), do: {tombstone, stamp}

  defp ensure_tombstone_stamp(tombstone, runtime) do
    stamp = Output.next_stamp(runtime.sid, runtime.boot)
    _ = Memento.Query.write(%{tombstone | stamp: stamp})
    {%{tombstone | stamp: stamp}, stamp}
  end

  defp membership_row(user, projection, records, runtime, channel_refs) do
    {:ok, membership, _statuses} =
      Projection.memberships(user, records, runtime.sid, runtime.boot, sid: runtime.sid, channel_refs: channel_refs)

    %{membership | "home" => projection["home"]}
  end

  defp policy_rows(payloads, _policy) do
    Enum.flat_map(payloads, fn
      %{"snapshot" => "policy", "phase" => "begin", "epoch" => epoch, "revision" => revision, "objects" => objects} ->
        [%{"kind" => "policy.cache.begin", "epoch" => epoch, "revision" => revision, "objects" => objects}]

      %{"snapshot" => "policy", "phase" => "rows", "rows" => rows} ->
        [%{"kind" => "policy.cache.rows", "rows" => rows}]

      %{"snapshot" => "policy", "phase" => "end", "epoch" => epoch, "revision" => revision, "objects" => objects} ->
        [%{"kind" => "policy.cache.end", "epoch" => epoch, "revision" => revision, "objects" => objects}]

      _payload ->
        []
    end)
  end

  defp apply_rows(runtime, rows, origin, context, options) do
    Enum.reduce_while(rows, {:ok, runtime, []}, fn row, {:ok, current, effects} ->
      case apply_row(current, row, origin, context, options) do
        {:ok, next, row_effects} -> {:cont, {:ok, next, effects ++ row_effects}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp apply_row(runtime, %{"kind" => "topology.add"} = row, origin, _context, options) do
    source_sid = Keyword.get(options, :source_sid, runtime.sid)

    with :ok <-
           Tree.validate_topology(
             row,
             runtime.roster,
             Map.new(runtime.nodes, fn {sid, node} -> {sid, node["boot"]} end),
             source_sid,
             require_incoming: origin["sid"] == source_sid
           ),
         {:ok, next} <- apply_topology_nodes(runtime, row["nodes"]),
         {:ok, next} <- apply_topology_edges(next, row["edges"]) do
      {:ok, next, [%{kind: :topology, row: row}]}
    end
  end

  defp apply_row(
         runtime,
         %{"kind" => "topology.ready", "edge_id" => edge_id, "side" => side} = row,
         origin,
         _context,
         _options
       ) do
    case runtime.edges[edge_id] do
      nil ->
        {:error, :unknown_edge}

      edge ->
        ready = Enum.uniq([side | edge.ready_sides]) |> Enum.sort()

        if side in [edge.a["sid"], edge.b["sid"]] and side == origin["sid"] do
          next = %{runtime | edges: Map.put(runtime.edges, edge_id, %{edge | ready_sides: ready})}
          next = if length(ready) == 2, do: refresh_reachability(next), else: next
          {:ok, next, [%{kind: :topology, row: row}]}
        else
          {:error, :invalid_topology_ready_side}
        end
    end
  end

  defp apply_row(
         runtime,
         %{"kind" => "topology.remove", "edge_id" => edge_id, "reporter" => reporter} = row,
         origin,
         _context,
         _options
       ) do
    case runtime.edges[edge_id] do
      nil ->
        {:ok, runtime, []}

      edge ->
        endpoints = [edge.a["sid"], edge.b["sid"]]

        if reporter in endpoints and reporter == origin["sid"] do
          next = %{runtime | edges: Map.delete(runtime.edges, edge_id)} |> refresh_reachability()
          {next, removed_channels} = prune_unreachable(next)

          {:ok, next, [%{kind: :topology, row: row, removed_channels: removed_channels}]}
        else
          {:error, :invalid_edge_reporter}
        end
    end
  end

  defp apply_row(runtime, %{"kind" => "merge.begin", "id" => id} = row, _origin, _context, _options) do
    {:ok, %{runtime | merge_contexts: MapSet.put(runtime.merge_contexts, id)}, [%{kind: :merge, row: row}]}
  end

  defp apply_row(runtime, %{"kind" => kind, "id" => id} = row, _origin, _context, _options)
       when kind in ~w(merge.end merge.abort) do
    {:ok, %{runtime | merge_contexts: MapSet.delete(runtime.merge_contexts, id)}, [%{kind: :merge, row: row}]}
  end

  defp apply_row(runtime, %{"kind" => "user.put", "user" => user} = row, origin, _context, options) do
    with :ok <- home_route(runtime, user, origin, options),
         {:ok, next} <- merge_user(runtime, user) do
      {:ok, next, [%{kind: :user, row: row}]}
    end
  end

  defp apply_row(
         runtime,
         %{"kind" => "user.quit", "uid" => uid, "home" => home, "rev" => rev} = row,
         origin,
         _context,
         options
       ) do
    with :ok <- home_route(runtime, %{"home" => home}, origin, options),
         true <- row_actor_authorized?(runtime, row["by"], origin, row, options) do
      case runtime.users[uid] do
        nil ->
          {:ok, runtime, []}

        user ->
          if rev < user["rev"] do
            {:ok, runtime, []}
          else
            previous_memberships = runtime.memberships[uid]

            next =
              %{runtime | users: Map.delete(runtime.users, uid), memberships: Map.delete(runtime.memberships, uid)}
              |> remove_user_statuses(uid)

            {next, removed_channels} =
              prune_empty_channels(next, membership_channel_names(previous_memberships, runtime.case_mapping))

            {:ok, next, [%{kind: :user_quit, row: row, user: user, removed_channels: removed_channels}]}
          end
      end
    else
      false -> {:error, :actor_authority_mismatch}
      {:error, _} = error -> error
    end
  end

  defp apply_row(
         runtime,
         %{"kind" => "memberships.put", "uid" => uid, "home" => home, "rev" => rev, "entries" => entries} = row,
         origin,
         _context,
         options
       ) do
    with :ok <- home_route(runtime, %{"home" => home}, origin, options),
         true <- row_actor_authorized?(runtime, row["cause"]["by"], origin, row, options) do
      case merge_memberships(runtime, uid, home, rev, entries, row["cause"]) do
        {:ok, next} -> {:ok, next, []}
        {:ok, next, effect} -> {:ok, next, [Map.put(effect, :row, row)]}
        {:error, _} = error -> error
      end
    else
      false -> {:error, :actor_authority_mismatch}
      {:error, _} = error -> error
    end
  end

  defp apply_row(runtime, %{"kind" => "channel.ensure", "channel" => ref} = row, _origin, _context, _options) do
    if String.starts_with?(ref["name"], "&") do
      {:error, :local_channel_not_replicated}
    else
      key = channel_key(runtime, ref["name"])

      case runtime.channels[key] do
        nil ->
          channel = %{ref: ref, registers: %{}, list_slots: %{}, statuses: %{}}
          {:ok, %{runtime | channels: Map.put(runtime.channels, key, channel)}, [%{kind: :channel, row: row}]}

        existing ->
          case State.incarnation(ref_to_state(existing.ref), ref_to_state(ref)) do
            :newer ->
              channel = %{ref: ref, registers: %{}, list_slots: %{}, statuses: %{}}
              {:ok, %{runtime | channels: Map.put(runtime.channels, key, channel)}, [%{kind: :channel, row: row}]}

            _ ->
              {:ok, runtime, []}
          end
      end
    end
  end

  defp apply_row(
         runtime,
         %{"kind" => "channel.field", "channel" => ref, "field" => field, "stamp" => stamp, "value" => value} = row,
         origin,
         _context,
         options
       ) do
    with :ok <- register_authorized?(runtime, stamp, row["setter"], origin, options),
         channel_result <- fetch_channel(runtime, ref) do
      case channel_result do
        {:ok, channel} ->
          with {:ok, channel, status} <- State.merge_channel_field(channel, field, stamp, value) do
            next = %{runtime | channels: Map.put(runtime.channels, channel_key(runtime, ref["name"]), channel)}
            if status == :unchanged, do: {:ok, runtime, []}, else: {:ok, next, [%{kind: :channel, row: row}]}
          end

        {:ignore, _reason} ->
          {:ok, runtime, []}

        {:error, _} = error ->
          error
      end
    end
  end

  defp apply_row(
         runtime,
         %{
           "kind" => "channel.list",
           "channel" => ref,
           "mode" => mode,
           "mask" => mask,
           "present" => present,
           "set_by" => set_by,
           "set_ms" => set_ms,
           "stamp" => stamp
         } = row,
         origin,
         _context,
         options
       ) do
    with :ok <- register_authorized?(runtime, stamp, nil, origin, options),
         channel_result <- fetch_channel(runtime, ref) do
      case channel_result do
        {:ok, channel} ->
          with {:ok, channel, status} <-
                 State.merge_list_slot(channel, {mode, mask}, stamp, present, %{set_by: set_by, set_ms: set_ms}) do
            next = %{runtime | channels: Map.put(runtime.channels, channel_key(runtime, ref["name"]), channel)}
            if status == :unchanged, do: {:ok, runtime, []}, else: {:ok, next, [%{kind: :channel, row: row}]}
          end

        {:ignore, _reason} ->
          {:ok, runtime, []}

        {:error, _} = error ->
          error
      end
    end
  end

  defp apply_row(
         runtime,
         %{
           "kind" => "member.status",
           "channel" => ref,
           "uid" => uid,
           "join_id" => join_id,
           "mode" => mode,
           "enabled" => enabled,
           "stamp" => stamp
         } = row,
         origin,
         _context,
         options
       ) do
    with :ok <- register_authorized?(runtime, stamp, row["setter"], origin, options),
         channel_result <- fetch_channel(runtime, ref) do
      case channel_result do
        {:ignore, _reason} ->
          {:ok, runtime, []}

        {:error, :missing_channel} ->
          {:ok, runtime, []}

        {:error, _} = error ->
          error

        {:ok, channel} ->
          if current_join?(runtime, uid, ref["name"], join_id) do
            key = {uid, join_id, mode}
            registers = Map.get(channel, :statuses, %{})

            case State.merge_register(Map.get(registers, key), stamp, %{enabled: enabled, setter: row["setter"]}) do
              {:ok, :unchanged, _} ->
                {:ok, runtime, []}

              {:ok, _status, register} ->
                channel = %{channel | statuses: Map.put(registers, key, register)}
                next = %{runtime | channels: Map.put(runtime.channels, channel_key(runtime, ref["name"]), channel)}
                {:ok, next, [%{kind: :status, row: row}]}

              {:error, _} = error ->
                error
            end
          else
            {:ok, runtime, []}
          end
      end
    end
  end

  defp apply_row(
         runtime,
         %{"kind" => "policy.change", "epoch" => epoch, "revision" => revision, "changes" => changes} = row,
         origin,
         _context,
         options
       ) do
    if policy_origin_allowed?(runtime, origin, options) do
      apply_policy_change(runtime, row, epoch, revision, changes)
    else
      {:error, :policy_authority_mismatch}
    end
  end

  defp apply_row(
         runtime,
         %{"kind" => "policy.cache.begin", "epoch" => epoch, "revision" => revision, "objects" => objects} = row,
         origin,
         _context,
         options
       ) do
    cond do
      not Keyword.get(options, :snapshot, false) ->
        {:error, :policy_cache_only_in_snapshot}

      runtime.policy_cache != nil ->
        {:error, :duplicate_policy_cache_begin}

      objects > 65_536 ->
        {:error, :policy_cache_too_large}

      true ->
        with true <- policy_origin_allowed?(runtime, origin, options),
             {:ok, runtime} <- accept_policy_cache_epoch(runtime, epoch) do
          cache = %{epoch: epoch, revision: revision, expected: objects, rows: [], keys: MapSet.new()}
          {:ok, %{runtime | policy_cache: cache}, [%{kind: :policy_cache, row: row}]}
        end
    end
  end

  defp apply_row(runtime, %{"kind" => "policy.cache.rows", "rows" => rows} = row, origin, _context, options) do
    cond do
      not Keyword.get(options, :snapshot, false) ->
        {:error, :policy_cache_only_in_snapshot}

      is_nil(runtime.policy_cache) ->
        {:error, :policy_cache_begin_missing}

      true ->
        cache = runtime.policy_cache

        with true <- policy_origin_allowed?(runtime, origin, options),
             {:ok, validated} <- validate_policy_cache_rows(rows),
             row_keys <- Enum.map(validated, &{&1["entity"], &1["key"]}),
             true <- Enum.all?(row_keys, &(not MapSet.member?(cache.keys, &1))),
             true <- length(cache.rows) + length(validated) <= 65_536 do
          next_cache = %{
            cache
            | rows: cache.rows ++ validated,
              keys: Enum.reduce(row_keys, cache.keys, &MapSet.put(&2, &1))
          }

          {:ok, %{runtime | policy_cache: next_cache}, [%{kind: :policy_cache, row: row}]}
        else
          false -> {:error, :invalid_policy_cache_rows}
          {:error, _} = error -> error
        end
    end
  end

  defp apply_row(
         runtime,
         %{"kind" => "policy.cache.end", "epoch" => epoch, "revision" => revision, "objects" => objects} = row,
         origin,
         _context,
         options
       ) do
    cond do
      not Keyword.get(options, :snapshot, false) ->
        {:error, :policy_cache_only_in_snapshot}

      is_nil(runtime.policy_cache) ->
        {:error, :policy_cache_begin_missing}

      true ->
        cache = runtime.policy_cache

        with true <- policy_origin_allowed?(runtime, origin, options),
             true <- cache.epoch == epoch and cache.revision == revision and cache.expected == objects,
             {:ok, policy} <- Policy.install_image(runtime.policy, epoch, revision, cache.rows),
             {:ok, runtime} <- recompute_nicknames(%{runtime | policy: policy, policy_cache: nil}) do
          {runtime, invalidation_effects} = invalidate_bindings(runtime, policy)

          {:ok, runtime, [%{kind: :policy_cache, row: row} | invalidation_effects]}
        else
          false -> {:error, :invalid_policy_cache_end}
          {:error, _} = error -> error
        end
    end
  end

  defp apply_row(runtime, %{"kind" => "invite.notice", "target_uid" => target_uid} = row, origin, _context, options) do
    with %{"home" => home} <- runtime.users[target_uid],
         :ok <- home_route(runtime, %{"home" => home}, origin, options),
         channel_result <- fetch_channel(runtime, row["channel"]) do
      case channel_result do
        {:ok, _channel} ->
          {:ok, runtime, [%{kind: :invite, row: row, origin: origin}]}

        {:ignore, _reason} ->
          {:ok, runtime, []}

        {:error, _} = error ->
          error
      end
    else
      nil -> {:error, :invite_target_missing}
      _ -> {:error, :invite_target_route}
    end
  end

  defp apply_row(_runtime, _row, _origin, _context, _options), do: {:error, :unsupported_state_row}

  defp apply_policy_change(runtime, row, epoch, revision, changes) do
    case Policy.apply_change(runtime.policy, epoch, revision, changes) do
      {:ok, _policy, :unchanged} ->
        {:ok, runtime, []}

      {:ok, policy, :invalidated} ->
        {:ok, %{runtime | policy: policy}, [%{kind: :policy, row: row}]}

      {:ok, policy, :applied} ->
        with {:ok, next} <- recompute_nicknames(%{runtime | policy: policy}) do
          {next, invalidation_effects} = invalidate_bindings(next, policy)
          {:ok, next, [%{kind: :policy, row: row} | invalidation_effects]}
        end

      {:error, _} = error ->
        error
    end
  end

  defp invalidate_bindings(runtime, policy) do
    {users, effects} =
      Enum.reduce(runtime.users, {%{}, []}, fn {uid, user}, {users, effects} ->
        case user["binding"] do
          %{"account_id" => account_id, "auth_epoch" => auth_epoch, "policy_epoch" => policy_epoch} = binding ->
            if binding_valid?(policy, account_id, auth_epoch, policy_epoch) do
              registered_nick? = registered_nick_owned?(policy, account_id, user)
              modes = user["modes"] || []
              next_modes = if registered_nick?, do: Enum.uniq(["r" | modes]), else: List.delete(modes, "r")

              if next_modes == modes do
                {Map.put(users, uid, user), effects}
              else
                next_user = Map.put(user, "modes", next_modes)
                effect = %{kind: :binding_mode, uid: uid, home: user["home"], enabled: registered_nick?}
                {Map.put(users, uid, next_user), [effect | effects]}
              end
            else
              next_user = %{user | "binding" => nil, "modes" => List.delete(user["modes"] || [], "r")}
              effect = %{kind: :binding_invalidated, uid: uid, home: user["home"], binding: binding}
              {Map.put(users, uid, next_user), [effect | effects]}
            end

          _ ->
            {Map.put(users, uid, user), effects}
        end
      end)

    {%{runtime | users: users}, Enum.reverse(effects)}
  end

  defp binding_valid?(policy, account_id, auth_epoch, policy_epoch) do
    with true <- Policy.grant_ready?(policy),
         true <- policy_epoch == policy.epoch,
         {:ok, %{"auth_epoch" => ^auth_epoch}} <- Policy.get(policy, "account", account_id) do
      true
    else
      _ -> false
    end
  end

  defp registered_nick_owned?(policy, account_id, user) do
    with {:ok, %{"aliases" => aliases}} <- Policy.get(policy, "account", account_id),
         nick when is_binary(nick) <- user["requested_nick"] || user["effective_nick"] do
      Enum.any?(aliases, &(CaseMapping.normalize(&1) == CaseMapping.normalize(nick)))
    else
      _ -> false
    end
  end

  defp validate_policy_cache_rows(rows) when is_list(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      %{"entity" => entity, "key" => key, "value" => value} = object, {:ok, acc} ->
        if Schema.validate_row(%{"kind" => "policy.cache.rows", "rows" => [object]}) == :ok and
             Policy.validate_public_object(entity, key, value) == :ok do
          {:cont, {:ok, [object | acc]}}
        else
          {:halt, {:error, :invalid_policy_cache_object}}
        end

      _object, _acc ->
        {:halt, {:error, :invalid_policy_cache_object}}
    end)
    |> case do
      {:ok, objects} -> {:ok, Enum.reverse(objects)}
      {:error, _} = error -> error
    end
  end

  defp validate_policy_cache_rows(_rows), do: {:error, :invalid_policy_cache_rows}

  defp merge_user(runtime, user) do
    uid = user["uid"]

    case runtime.users[uid] do
      nil ->
        {:ok, %{runtime | users: Map.put(runtime.users, uid, user)}}

      existing ->
        cond do
          existing["home"] != user["home"] -> {:error, :uid_home_conflict}
          user["rev"] > existing["rev"] -> {:ok, %{runtime | users: Map.put(runtime.users, uid, user)}}
          user["rev"] == existing["rev"] and owner_projection(existing) == user -> {:ok, runtime}
          user["rev"] == existing["rev"] -> {:error, :user_revision_conflict}
          true -> {:ok, runtime}
        end
    end
  end

  defp owner_projection(user), do: Map.delete(user, "effective_nick")

  defp merge_memberships(runtime, uid, home, rev, entries, cause) do
    if not Map.has_key?(runtime.users, uid) do
      {:error, :membership_owner_missing}
    else
      current = runtime.memberships[uid] || %{rev: 0, entries: [], home: home, cause: cause}

      case State.replace_memberships(current.rev, current.entries, rev, entries, case_mapping: runtime.case_mapping) do
        {:ok, diff} ->
          if rev == current.rev do
            {:ok, runtime}
          else
            next = %{
              runtime
              | memberships: Map.put(runtime.memberships, uid, %{rev: rev, entries: entries, home: home, cause: cause})
            }

            next = prune_user_statuses(next, uid, entries)
            removed_candidates = removed_channel_names(current.entries, entries, runtime.case_mapping)
            {next, removed_channels} = prune_empty_channels(next, removed_candidates)

            effect = %{
              kind: :memberships,
              uid: uid,
              previous: current,
              current: next.memberships[uid],
              diff: diff,
              row: %{
                "kind" => "memberships.put",
                "uid" => uid,
                "home" => home,
                "rev" => rev,
                "entries" => entries,
                "cause" => cause
              },
              removed_channels: removed_channels
            }

            {:ok, next, effect}
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp recompute_nicknames(runtime) do
    claims = Enum.map(runtime.users, fn {uid, user} -> %{uid: uid, requested_nick: user["requested_nick"]} end)

    case State.nickname_projection(claims, case_mapping: runtime.case_mapping) do
      {:ok, projection} ->
        users =
          Enum.reduce(projection, runtime.users, fn {uid, nick}, users ->
            put_in(users, [uid, "effective_nick"], nick)
          end)

        {:ok, %{runtime | users: users}}

      {:error, _} = error ->
        error
    end
  end

  defp apply_topology_nodes(runtime, nodes) do
    duplicate_sids? = length(Enum.map(nodes, & &1["sid"])) != length(Enum.uniq(Enum.map(nodes, & &1["sid"])))

    if duplicate_sids? do
      {:error, :duplicate_topology_sid}
    else
      Enum.reduce_while(nodes, :ok, fn node, :ok ->
        case runtime.nodes[node["sid"]] do
          nil ->
            if Enum.any?(runtime.roster, &(&1.sid == node["sid"])),
              do: {:cont, :ok},
              else: {:halt, {:error, :unknown_topology_sid}}

          existing ->
            if existing["boot"] == node["boot"], do: {:cont, :ok}, else: {:halt, {:error, :duplicate_live_boot}}
        end
      end)
      |> case do
        :ok -> {:ok, %{runtime | nodes: Enum.reduce(nodes, runtime.nodes, &Map.put(&2, &1["sid"], &1))}}
        {:error, _} = error -> error
      end
    end
  end

  defp apply_topology_edges(runtime, edges) do
    duplicate_ids? = length(Enum.map(edges, & &1["id"])) != length(Enum.uniq(Enum.map(edges, & &1["id"])))

    duplicate_pairs? =
      edges
      |> Enum.map(&Enum.sort([&1["a"]["sid"], &1["b"]["sid"]]))
      |> then(&(length(&1) != length(Enum.uniq(&1))))

    if duplicate_ids? or duplicate_pairs? do
      {:error, :duplicate_topology_edge}
    else
      Enum.reduce_while(edges, {:ok, runtime}, fn edge, {:ok, current} ->
        a = edge["a"]["sid"]
        b = edge["b"]["sid"]
        known_a = current.nodes[a]
        known_b = current.nodes[b]

        if is_map(known_a) and is_map(known_b) and known_a["boot"] == edge["a"]["boot"] and
             known_b["boot"] == edge["b"]["boot"] and
             (Tree.initiator_allowed?(current.roster, a, b) or Tree.initiator_allowed?(current.roster, b, a)) do
          edge_value = %{
            id: edge["id"],
            a: edge["a"],
            b: edge["b"],
            ready_sides: merge_ready_sides(current.edges[edge["id"]], edge["ready_sides"])
          }

          {:cont, {:ok, %{current | edges: Map.put(current.edges, edge["id"], edge_value)}}}
        else
          {:halt, {:error, :unconfigured_edge}}
        end
      end)
      |> case do
        {:ok, next} -> {:ok, refresh_reachability(next)}
        {:error, _} = error -> error
      end
    end
  end

  defp refresh_reachability(runtime) do
    ready_edges = runtime.edges |> Map.values() |> Enum.filter(&(length(&1.ready_sides) == 2))
    reachable = traverse(runtime.sid, ready_edges, MapSet.new([runtime.sid]))

    %{
      runtime
      | active_edges: MapSet.new(Enum.map(ready_edges, &edge_key(&1.a["sid"], &1.b["sid"]))),
        reachable_sids: reachable
    }
  end

  defp merge_ready_sides(nil, ready_sides), do: Enum.sort(Enum.uniq(ready_sides))

  defp merge_ready_sides(existing, ready_sides),
    do: Enum.sort(Enum.uniq(existing.ready_sides ++ ready_sides))

  defp traverse(sid, edges, visited) do
    next =
      edges
      |> Enum.flat_map(fn edge ->
        cond do
          edge.a["sid"] == sid -> [edge.b["sid"]]
          edge.b["sid"] == sid -> [edge.a["sid"]]
          true -> []
        end
      end)
      |> Enum.reject(&MapSet.member?(visited, &1))

    Enum.reduce(next, visited, fn neighbor, current ->
      traverse(neighbor, edges, MapSet.put(current, neighbor))
    end)
  end

  defp prune_unreachable(runtime) do
    reachable = runtime.reachable_sids

    nodes =
      runtime.nodes
      |> Enum.filter(fn {sid, _node} -> MapSet.member?(reachable, sid) end)
      |> Map.new()

    edges =
      runtime.edges
      |> Enum.filter(fn {_id, edge} ->
        MapSet.member?(reachable, edge.a["sid"]) and MapSet.member?(reachable, edge.b["sid"])
      end)
      |> Map.new()

    users =
      Enum.filter(runtime.users, fn {_uid, user} -> MapSet.member?(runtime.reachable_sids, user["home"]["sid"]) end)
      |> Map.new()

    memberships = Map.take(runtime.memberships, Map.keys(users))

    channels =
      Map.new(runtime.channels, fn {key, channel} ->
        statuses =
          Enum.filter(channel.statuses, fn {{uid, _join_id, _mode}, _register} -> Map.has_key?(users, uid) end)
          |> Map.new()

        {key, %{channel | statuses: statuses}}
      end)

    next = %{
      runtime
      | nodes: nodes,
        edges: edges,
        users: users,
        memberships: memberships,
        channels: channels,
        merge_contexts: MapSet.new()
    }

    prune_empty_channels(next, Map.keys(next.channels))
  end

  defp prune_empty_channels(runtime, candidates) when is_list(candidates) do
    candidate_keys =
      candidates
      |> Enum.map(&normalize(&1, runtime.case_mapping))
      |> MapSet.new()

    removed_keys =
      runtime.channels
      |> Enum.filter(fn {key, channel} ->
        MapSet.member?(candidate_keys, key) and
          not channel_has_members?(runtime, channel.ref["name"]) and
          not guarded_channel?(runtime, key)
      end)
      |> Enum.map(&elem(&1, 0))

    {%{runtime | channels: Map.drop(runtime.channels, removed_keys)}, removed_keys}
  end

  defp prune_empty_channels(runtime, _candidates), do: {runtime, []}

  defp channel_has_members?(runtime, channel_name) do
    key = normalize(channel_name, runtime.case_mapping)

    Enum.any?(runtime.memberships, fn {_uid, membership} ->
      Enum.any?(membership.entries, &(normalize(&1["channel"], runtime.case_mapping) == key))
    end)
  end

  defp guarded_channel?(runtime, channel_key) do
    case Policy.get(runtime.policy, "channel", channel_key) do
      {:ok, %{"settings" => %{"guard" => true}}} -> true
      _ -> false
    end
  end

  defp membership_channel_names(%{entries: entries}, mapping),
    do: Enum.map(entries, &normalize(&1["channel"], mapping))

  defp membership_channel_names(_membership, _mapping), do: []

  defp removed_channel_names(previous, current, mapping) when is_list(previous) and is_list(current) do
    current_keys = MapSet.new(current, &normalize(&1["channel"], mapping))

    previous
    |> Enum.map(&normalize(&1["channel"], mapping))
    |> Enum.reject(&MapSet.member?(current_keys, &1))
    |> Enum.uniq()
  end

  defp removed_channel_names(_previous, _current, _mapping), do: []

  defp remove_user_statuses(runtime, uid) do
    channels =
      Map.new(runtime.channels, fn {key, channel} ->
        statuses =
          Enum.reject(channel.statuses, fn {{status_uid, _join_id, _mode}, _register} -> status_uid == uid end)
          |> Map.new()

        {key, %{channel | statuses: statuses}}
      end)

    %{runtime | channels: channels}
  end

  defp prune_user_statuses(runtime, uid, entries) do
    valid_joins = MapSet.new(Enum.map(entries, &{normalize(&1["channel"], runtime.case_mapping), &1["join_id"]}))

    channels =
      Map.new(runtime.channels, fn {key, channel} ->
        statuses =
          Enum.reject(channel.statuses, fn {{status_uid, join_id, _mode}, _register} ->
            status_uid == uid and
              not MapSet.member?(valid_joins, {normalize(channel.ref["name"], runtime.case_mapping), join_id})
          end)
          |> Map.new()

        {key, %{channel | statuses: statuses}}
      end)

    %{runtime | channels: channels}
  end

  defp register_authorized?(runtime, [_, stamp_sid, stamp_boot], setter, origin, options) do
    snapshot? = Keyword.get(options, :snapshot, false)
    stamp_known? = Map.get(runtime.nodes, stamp_sid, %{})["boot"] == stamp_boot
    stamp_route? = (snapshot? and stamp_known?) or (stamp_sid == origin["sid"] and stamp_boot == origin["boot"])

    if stamp_route? and actor_authorized?(runtime, setter, %{"sid" => stamp_sid, "boot" => stamp_boot}, snapshot?),
      do: :ok,
      else: {:error, :register_authority_mismatch}
  end

  defp register_authorized?(_runtime, _stamp, _setter, _origin, _options), do: {:error, :register_authority_mismatch}

  defp actor_authorized?(_runtime, nil, _origin, _snapshot?), do: true

  defp actor_authorized?(runtime, %{"server" => sid}, %{"sid" => origin_sid}, snapshot?) do
    sid == origin_sid or (snapshot? and Map.has_key?(runtime.nodes, sid))
  end

  defp actor_authorized?(runtime, %{"service" => service}, %{"sid" => origin_sid}, _snapshot?)
       when service in ~w(NickServ ChanServ),
       do: runtime.services_authority == origin_sid

  defp actor_authorized?(runtime, %{"user" => uid}, origin, snapshot?) do
    case runtime.users[uid] do
      %{"home" => %{"sid" => sid, "boot" => boot}} ->
        snapshot? or (sid == origin["sid"] and boot == origin["boot"])

      _ ->
        false
    end
  end

  defp actor_authorized?(_runtime, _actor, _origin, _snapshot?), do: false

  defp row_actor_authorized?(runtime, actor, origin, row, options) do
    actor_authorized?(runtime, actor, origin, Keyword.get(options, :snapshot, false)) or
      local_owner_row?(row, origin, options) or
      owner_row_actor_authorized?(runtime, actor, origin, row, options)
  end

  defp local_owner_row?(%{"kind" => kind, "home" => home}, origin, options)
       when kind in ["memberships.put", "user.quit"] do
    Keyword.get(options, :local_owner, false) and home == origin
  end

  defp local_owner_row?(_row, _origin, _options), do: false

  defp owner_row_actor_authorized?(runtime, actor, origin, %{"kind" => kind, "home" => home}, options)
       when kind in ["memberships.put", "user.quit"] do
    not Keyword.get(options, :snapshot, false) and home == origin and known_actor?(runtime, actor)
  end

  defp owner_row_actor_authorized?(_runtime, _actor, _origin, _row, _options), do: false

  defp known_actor?(runtime, %{"user" => uid}) when is_binary(uid),
    do: match?(%{"home" => _}, runtime.users[uid])

  defp known_actor?(runtime, %{"server" => sid}) when is_binary(sid),
    do: Map.has_key?(runtime.nodes, sid) or sid == runtime.sid

  defp known_actor?(runtime, %{"service" => service}) when service in ["NickServ", "ChanServ"],
    do: runtime.services_authority in [runtime.sid | Map.keys(runtime.nodes)] and service in ["NickServ", "ChanServ"]

  defp known_actor?(_runtime, _actor), do: false

  defp policy_origin_allowed?(runtime, %{"sid" => sid, "boot" => boot}, _options) do
    sid == runtime.services_authority and Map.get(runtime.nodes, sid, %{})["boot"] == boot
  end

  defp policy_origin_allowed?(_runtime, _origin, _options), do: false

  defp accept_policy_cache_epoch(%{policy: %{ready?: true, epoch: epoch}} = runtime, epoch), do: {:ok, runtime}

  defp accept_policy_cache_epoch(%{policy: %{ready?: true}}, _epoch),
    do: {:error, :policy_epoch_mismatch}

  defp accept_policy_cache_epoch(%{policy: policy} = runtime, epoch) do
    {:ok, %{runtime | policy: %{policy | epoch: epoch, revision: 0, objects: %{}, ready?: false}}}
  end

  defp source_allowed?(runtime, origin, source_sid, snapshot?, changes) do
    origin_known? = origin["sid"] != nil and Map.get(runtime.nodes, origin["sid"], %{})["boot"] == origin["boot"]
    topology_bootstrap? = topology_bootstrap_origin_allowed?(runtime, origin, source_sid, changes)

    cond do
      topology_bootstrap? ->
        :ok

      origin["sid"] == source_sid and origin_known? ->
        :ok

      not origin_known? ->
        {:error, :invalid_origin_route}

      snapshot? and Map.has_key?(runtime.nodes, source_sid) ->
        :ok

      origin["sid"] == runtime.sid and source_sid == runtime.sid ->
        :ok

      true ->
        case Tree.active_route(runtime.roster, runtime.sid, origin["sid"], runtime.active_edges) do
          {:ok, [_local, ^source_sid | _]} -> :ok
          _ -> {:error, :invalid_origin_route}
        end
    end
  end

  defp topology_ready_allowed?(runtime, origin, source_sid, edge_id, side) do
    with %{"sid" => origin_sid, "boot" => origin_boot} <- origin,
         true <- Identity.valid_sid?(origin_sid),
         true <- Identity.valid_id?(origin_boot),
         true <- origin_sid == side,
         true <- source_sid != origin_sid,
         {:ok, [^source_sid | _]} <- Tree.path(runtime.roster, source_sid, origin_sid) do
      case Map.get(runtime.edges, edge_id) do
        nil ->
          true

        %{a: %{"sid" => left}, b: %{"sid" => right}} ->
          origin_sid in [left, right] and
            (Tree.initiator_allowed?(runtime.roster, left, right) or
               Tree.initiator_allowed?(runtime.roster, right, left))

        _ ->
          false
      end
    else
      _ -> false
    end
  end

  defp topology_add_allowed?(runtime, origin, source_sid, nodes, edges)
       when is_list(nodes) and is_list(edges) do
    with %{"sid" => origin_sid} <- origin,
         true <- origin_sid != source_sid,
         true <- Enum.any?(nodes, &(&1["sid"] == origin_sid)),
         true <- Enum.any?(nodes, &(&1["sid"] == source_sid)),
         true <- edges != [],
         {:ok, [^source_sid | _]} <- Tree.path(runtime.roster, source_sid, origin_sid) do
      true
    else
      _ -> false
    end
  end

  defp topology_add_allowed?(_runtime, _origin, _source_sid, _nodes, _edges), do: false

  defp merge_context_allowed?(_runtime, %{"kind" => "live"}), do: :ok

  defp merge_context_allowed?(runtime, %{"kind" => "merge", "id" => id}),
    do: if(MapSet.member?(runtime.merge_contexts, id), do: :ok, else: {:error, :unknown_merge_context})

  defp home_route(_runtime, %{"home" => %{"sid" => sid, "boot" => boot}}, %{"sid" => sid, "boot" => boot}, _options),
    do: :ok

  defp home_route(runtime, %{"home" => %{"sid" => sid, "boot" => boot}}, _origin, options) do
    if Keyword.get(options, :snapshot, false) and Map.get(runtime.nodes, sid, %{})["boot"] == boot,
      do: :ok,
      else: {:error, :home_origin_mismatch}
  end

  defp fetch_channel(runtime, ref) do
    case runtime.channels[channel_key(runtime, ref["name"])] do
      nil ->
        {:error, :missing_channel}

      channel ->
        case State.incarnation(ref_to_state(channel.ref), ref_to_state(ref)) do
          :same -> {:ok, channel}
          :newer -> {:error, :channel_not_ensured}
          :older -> {:ignore, :stale_channel_incarnation}
        end
    end
  end

  defp current_join?(runtime, uid, channel, join_id) do
    membership = runtime.memberships[uid]

    is_map(membership) and
      Enum.any?(membership.entries, fn entry ->
        normalize(entry["channel"], runtime.case_mapping) == normalize(channel, runtime.case_mapping) and
          entry["join_id"] == join_id
      end)
  end

  defp channel_rows(channel, sid) do
    fields =
      Enum.map(channel.registers, fn {field, register} ->
        %{
          "kind" => "channel.field",
          "channel" => channel.ref,
          "field" => field,
          "value" => register.value,
          "stamp" => register.stamp,
          "setter" => %{"server" => sid}
        }
      end)

    lists =
      Enum.map(channel.list_slots, fn {{mode, mask}, register} ->
        %{
          "kind" => "channel.list",
          "channel" => channel.ref,
          "mode" => mode,
          "mask" => mask,
          "present" => register.value.present,
          "set_by" => register.value.set_by,
          "set_ms" => register.value.set_ms,
          "stamp" => register.stamp
        }
      end)

    fields ++ lists
  end

  defp status_rows(channel) do
    Enum.map(channel.statuses, fn {{uid, join_id, mode}, register} ->
      %{
        "kind" => "member.status",
        "channel" => channel.ref,
        "uid" => uid,
        "join_id" => join_id,
        "mode" => mode,
        "enabled" => register.value.enabled,
        "stamp" => register.stamp,
        "setter" => register.value.setter
      }
    end)
  end

  defp ref_to_state(%{"born_ms" => born_ms, "cid" => cid}), do: %{born_ms: born_ms, cid: cid}
  defp ref_to_state(%{born_ms: born_ms, cid: cid}), do: %{born_ms: born_ms, cid: cid}

  defp channel_ref(channel) do
    %{
      "name" => channel.name,
      "born_ms" => max(channel.born_ms || DateTime.to_unix(channel.created_at, :millisecond), 1),
      "cid" => channel.cid
    }
  end

  defp channel_key(runtime, name), do: normalize(name, runtime.case_mapping)
  defp edge_key(left, right), do: {min(left, right), max(left, right)}

  defp section(config, key) when is_map(config), do: Map.get(config, key, Map.get(config, Atom.to_string(key), %{}))
  defp section(config, key) when is_list(config), do: Keyword.get(config, key, [])
  defp section(_config, _key), do: []

  defp value(section, key, default) when is_map(section),
    do: Map.get(section, key, Map.get(section, Atom.to_string(key), default))

  defp value(section, key, default) when is_list(section), do: Keyword.get(section, key, default)
  defp value(_section, _key, default), do: default

  defp normalize(value, :ascii), do: ascii_lower(value)

  defp normalize(value, :strict_rfc1459),
    do:
      value
      |> ascii_lower()
      |> String.replace(["{", "}", "|"], fn
        "{" -> "["
        "}" -> "]"
        "|" -> "\\"
      end)

  defp normalize(value, _mapping),
    do:
      value
      |> ascii_lower()
      |> String.replace(["{", "}", "|", "~"], fn
        "{" -> "["
        "}" -> "]"
        "|" -> "\\"
        "~" -> "^"
      end)

  defp ascii_lower(value) when is_binary(value),
    do: for(<<byte <- value>>, into: <<>>, do: <<if(byte in ?A..?Z, do: byte + 32, else: byte)>>)
end
