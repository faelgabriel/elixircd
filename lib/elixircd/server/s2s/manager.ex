defmodule ElixIRCd.Server.S2S.Manager do
  @moduledoc """
  The one node-local ENP/1 manager.

  It owns configured-tree admission, link generations, snapshot barriers and
  the immutable runtime projection. Socket handlers and connectors only move
  bytes; this process decides which authenticated edge may affect state.
  """

  use GenServer

  require Logger

  import ElixIRCd.Utils.MessageFilter, only: [filter_auditorium_users: 3]
  import ElixIRCd.Utils.Protocol, only: [user_mask: 2]

  alias ElixIRCd.Message
  alias ElixIRCd.Commands.Cap
  alias ElixIRCd.ModeRegistry
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.UserAccepts
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Delivery
  alias ElixIRCd.Server.S2S.Domain
  alias ElixIRCd.Server.S2S.LocalChannel
  alias ElixIRCd.Server.S2S.Profile
  alias ElixIRCd.Server.S2S.Publication
  alias ElixIRCd.Server.S2S.QueryEndpoint
  alias ElixIRCd.Server.S2S.Requests
  alias ElixIRCd.Server.S2S.Runtime
  alias ElixIRCd.Server.S2S.Schema
  alias ElixIRCd.Server.S2S.SASL
  alias ElixIRCd.Server.S2S.SASL.Pool
  alias ElixIRCd.Server.S2S.RemoteSASL
  alias ElixIRCd.Server.S2S.ServiceEndpoint
  alias ElixIRCd.Server.S2S.Session
  alias ElixIRCd.Server.S2S.Sync
  alias ElixIRCd.Server.S2S.TLS
  alias ElixIRCd.Server.S2S.Tree
  alias ElixIRCd.Server.S2S.View
  alias ElixIRCd.Server.S2S.Output
  alias ElixIRCd.Server.S2S.Policy
  alias ElixIRCd.Server.S2S.PolicyStore
  alias ElixIRCd.Utils.Nickserv
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Monitor

  @heartbeat_message :s2s_heartbeat
  @request_expiry_message :s2s_request_expiry
  @message_delivery_ttl_ms 15_000
  @stable_active_message :s2s_stable_active
  @finish_shutdown_message :s2s_finish_shutdown
  @binding_invalidation_key {__MODULE__, :binding_invalidation}
  @binding_mode_key {__MODULE__, :binding_mode}
  @status_materialization_key {__MODULE__, :status_materialization}

  @doc "Starts the node-local ENP/1 manager."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    case Keyword.fetch(options, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, options, name: name)
      :error -> GenServer.start_link(__MODULE__, options)
    end
  end

  @doc "Returns the hello that is sent on every fresh TLS generation."
  @spec local_hello(GenServer.server()) :: map()
  def local_hello(server \\ __MODULE__), do: GenServer.call(server, :local_hello)

  @doc "Checks a certificate presented on the dedicated incoming listener."
  @spec admit_peer(GenServer.server(), :incoming, map()) :: {:ok, map()} | {:error, term()}
  def admit_peer(server, direction, peer_info), do: GenServer.call(server, {:admit_peer, direction, peer_info})

  @doc "Checks the configured parent pin for an outbound socket."
  @spec admit_outbound(GenServer.server(), String.t(), map()) :: :ok | {:error, term()}
  def admit_outbound(server, peer_sid, peer_info), do: GenServer.call(server, {:admit_outbound, peer_sid, peer_info})

  @doc "Registers a session before its hello is released."
  @spec register_session(GenServer.server(), pid(), map()) :: {:ok, term()} | {:error, term()}
  def register_session(server, session, metadata), do: GenServer.call(server, {:register_session, session, metadata})

  @doc "Checks the claimed hello against the authenticated configured edge."
  @spec admit_hello(GenServer.server(), pid(), map()) :: :ok | {:error, term()}
  def admit_hello(server, session, frame), do: GenServer.call(server, {:admit_hello, session, frame})

  @doc "Reports a session or transport event to the manager."
  @spec session_event(GenServer.server(), pid(), term()) :: :ok
  def session_event(server, session, event) do
    send(server, {:s2s_session_event, session, event})
    :ok
  end

  @doc "Removes an exact session generation after a terminal socket event."
  @spec link_closed(GenServer.server(), pid(), term()) :: :ok
  def link_closed(server, session, reason) do
    send(server, {:s2s_link_closed, session, reason})
    :ok
  end

  @doc "Publishes one already committed local state row."
  @spec publish_row(GenServer.server(), map()) :: :ok | {:error, term()}
  def publish_row(server, row), do: GenServer.call(server, {:publish_row, row})

  @doc "Publishes one committed channel status change with a fresh local stamp."
  @spec publish_member_status(GenServer.server(), map(), String.t(), pos_integer(), String.t(), boolean(), String.t()) ::
          :ok | {:error, term()}
  def publish_member_status(server, channel, uid, join_id, mode, enabled, setter)
      when is_map(channel) and is_binary(uid) and is_integer(join_id) and is_binary(mode) and is_boolean(enabled) and
             is_binary(setter) do
    GenServer.call(server, {:publish_member_status, channel, uid, join_id, mode, enabled, setter})
  end

  @doc "Publishes one bounded committed local state group through the sole ENP path."
  @spec publish_rows(GenServer.server(), [map()]) :: :ok | {:error, term()}
  def publish_rows(server, rows), do: GenServer.call(server, {:publish_rows, rows})

  @doc "Refreshes the authority policy after a committed local service mutation."
  @spec refresh_policy(GenServer.server()) :: :ok | {:error, term()}
  def refresh_policy(server \\ __MODULE__), do: GenServer.call(server, :refresh_policy)

  @doc "Returns a bounded diagnostic projection."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Returns the immutable local network projection for C2S view and routing code."
  @spec runtime_view(GenServer.server()) :: map()
  def runtime_view(server \\ __MODULE__), do: GenServer.call(server, :runtime_view)

  @doc "Originates one admitted transient message from a local user."
  @spec publish_message(
          GenServer.server(),
          Identity.id(),
          map(),
          String.t(),
          String.t() | nil,
          map(),
          Identity.id() | nil,
          keyword()
        ) ::
          :ok | {:error, term()}
  def publish_message(server, actor_uid, target, command, text, tags \\ %{}, request_id \\ nil, options \\ []),
    do: GenServer.call(server, {:publish_message, actor_uid, target, command, text, tags, request_id, options})

  @doc "Clears a permanent parent-link retry block after operator correction."
  @spec retry_parent(GenServer.server()) :: :ok
  def retry_parent(server \\ __MODULE__), do: GenServer.call(server, :retry_parent)

  @doc "Stops native S2S after closing the current link generations."
  @spec shutdown(GenServer.server()) :: :ok
  def shutdown(server \\ __MODULE__), do: GenServer.call(server, :shutdown)

  @doc "Enables and, for a local child, retries one configured direct edge."
  @spec connect_neighbor(GenServer.server(), String.t()) :: {:ok, :connecting | :awaiting_child} | {:error, term()}
  def connect_neighbor(server, target), do: GenServer.call(server, {:connect_neighbor, target})

  @doc "Disables one configured direct edge and closes its current generation."
  @spec disable_neighbor(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def disable_neighbor(server, target, reason \\ "operator SQUIT"),
    do: GenServer.call(server, {:disable_neighbor, target, reason})

  @doc "Returns only configured topology nodes reachable through ready ENP edges."
  @spec topology_links(GenServer.server()) :: [map()]
  def topology_links(server \\ __MODULE__), do: GenServer.call(server, :topology_links)

  @doc "Originates one bounded request to a currently reachable node."
  @spec request(GenServer.server(), String.t(), map(), String.t(), map(), map(), pos_integer()) ::
          {:ok, Identity.id()} | {:error, term()}
  def request(server, target_sid, actor, method, args, guards, ttl_ms \\ 15_000),
    do: GenServer.call(server, {:request, target_sid, actor, method, args, guards, ttl_ms})

  @doc "Originates a request and delivers its terminal or streamed replies to one C2S process."
  @spec request_with_reply(
          GenServer.server(),
          String.t(),
          map(),
          String.t(),
          map(),
          map(),
          pid(),
          String.t(),
          pos_integer()
        ) :: {:ok, Identity.id()} | {:error, term()}
  def request_with_reply(server, target_sid, actor, method, args, guards, recipient, uid, ttl_ms \\ 15_000)
      when is_pid(recipient) and is_binary(uid) do
    request_with_reply_context(server, target_sid, actor, method, args, guards, recipient, uid, %{}, ttl_ms)
  end

  @doc "Originates a request with bounded C2S response metadata."
  @spec request_with_reply_context(
          GenServer.server(),
          String.t(),
          map(),
          String.t(),
          map(),
          map(),
          pid(),
          String.t(),
          map(),
          pos_integer()
        ) :: {:ok, Identity.id()} | {:error, term()}
  def request_with_reply_context(
        server,
        target_sid,
        actor,
        method,
        args,
        guards,
        recipient,
        uid,
        response_context,
        ttl_ms \\ 15_000
      )
      when is_pid(recipient) and is_binary(uid) and is_map(response_context) do
    GenServer.call(
      server,
      {:request_with_reply_context, target_sid, actor, method, args, guards, {recipient, uid, response_context}, ttl_ms}
    )
  end

  @doc "Cancels requests that are bound to one C2S connection generation."
  @spec cancel_recipient(GenServer.server(), pid(), String.t()) :: :ok
  def cancel_recipient(server, recipient, uid) when is_pid(recipient) and is_binary(uid) do
    send(server, {:s2s_cancel_recipient, recipient, uid})
    :ok
  end

  @doc "Silently cancels the in-flight ENP requests for one remote SASL attempt."
  @spec cancel_sasl_attempt(GenServer.server(), pid(), String.t(), String.t()) :: :ok
  def cancel_sasl_attempt(server, recipient, uid, attempt_id)
      when is_pid(recipient) and is_binary(uid) and is_binary(attempt_id) do
    send(server, {:s2s_cancel_sasl_attempt, recipient, uid, attempt_id})
    :ok
  end

  @impl true
  def init(options) do
    config = Keyword.get(options, :config, Application.get_all_env(:elixircd))

    with {:ok, _fenced_groups} <- Output.fence_pending(),
         :ok <- Profile.validate(config),
         {:ok, runtime} <- Runtime.new(config),
         :ok <- publish_identity(config, runtime),
         {:ok, runtime} <- Runtime.bootstrap(runtime),
         {:ok, sasl_pool} <-
           Pool.start_link(max_workers: value(section(section(config, :s2s), :budgets), :sasl_workers, 4)) do
      s2s = section(config, :s2s)
      boot = runtime.boot
      hello = Profile.hello(config, boot, Identity.nonce())
      roster = runtime.roster

      parent_sid =
        case Tree.parent(roster, runtime.sid) do
          {:ok, sid} -> sid
          _ -> nil
        end

      heartbeat_ms = value(section(s2s, :timeouts), :heartbeat_ms, 30_000)

      state = %{
        config: config,
        s2s: s2s,
        runtime: runtime,
        local_hello: hello,
        roster: roster,
        parent_sid: parent_sid,
        sessions: %{},
        sessions_by_peer: %{},
        parent_connector: nil,
        parent_timer: nil,
        stable_timer: nil,
        reconnect_attempt: 0,
        output_cut: 0,
        requests:
          Requests.new(
            max_pending: value(section(s2s, :budgets), :max_pending_requests_node, 1_024),
            max_pending_origin: value(section(s2s, :budgets), :max_pending_requests_origin, 128)
          ),
        request_waiters: %{},
        message_waiters: %{},
        channel_repairs: %{},
        policy_repairs: %{},
        service_jobs: %{},
        sync_jobs: %{},
        rehash_pid: nil,
        rehash_monitor: nil,
        service_workers: value(section(s2s, :budgets), :service_workers, 4),
        sasl_attempts: %{},
        sasl_pool: sasl_pool,
        sasl_jobs: %{},
        delivery_fun: Keyword.get(options, :delivery_fun, &Delivery.deliver_local/2),
        request_fun: Keyword.get(options, :request_fun),
        query_fun: Keyword.get(options, :query_fun, &QueryEndpoint.execute/3),
        service_fun: Keyword.get(options, :service_fun, &ElixIRCd.Server.S2S.ServiceEndpoint.execute/3),
        action_fun: Keyword.get(options, :action_fun),
        snapshot_fun: Keyword.get(options, :snapshot_fun),
        sync_capture_fun: Keyword.get(options, :sync_capture_fun, &Sync.capture/3),
        admin_fun: Keyword.get(options, :admin_fun),
        lifecycle_fun: Keyword.get(options, :lifecycle_fun),
        rehash_fun: Keyword.get(options, :rehash_fun, &ElixIRCd.Utils.System.load_configurations/0),
        reply_fun: Keyword.get(options, :reply_fun),
        sasl_options: Keyword.get(options, :sasl_options, RemoteSASL.authority_options()),
        disabled_edges: MapSet.new(),
        retry_blocked?: false,
        connector_error: nil,
        last_link_error: nil,
        lifecycle: :running,
        shutdown_timer: nil,
        heartbeat_ms: heartbeat_ms,
        heartbeat_timer: nil
      }

      {:ok, state, {:continue, :start}}
    else
      {:error, reason} -> {:stop, {:invalid_s2s_configuration, reason}}
    end
  end

  @impl true
  def handle_continue(:start, state) do
    heartbeat_timer = Process.send_after(self(), @heartbeat_message, state.heartbeat_ms)
    send(self(), @request_expiry_message)
    state = %{state | heartbeat_timer: heartbeat_timer}
    {:noreply, schedule_parent(state, 0)}
  end

  @impl true
  def handle_call(:local_hello, _from, state) do
    hello = %{state.local_hello | "nonce" => Identity.nonce(), "time_ms" => Identity.now_ms()}
    {:reply, hello, state}
  end

  def handle_call({:admit_peer, _direction, _peer_info}, _from, %{lifecycle: :closing} = state),
    do: {:reply, {:error, :shutting_down}, state}

  def handle_call({:admit_peer, :incoming, peer_info}, _from, state) do
    case incoming_peer(state, peer_info) do
      {:ok, peer} -> {:reply, {:ok, peer}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:admit_peer, _direction, _peer_info}, _from, state),
    do: {:reply, {:error, :invalid_link_direction}, state}

  def handle_call({:admit_outbound, _peer_sid, _peer_info}, _from, %{lifecycle: :closing} = state),
    do: {:reply, {:error, :shutting_down}, state}

  def handle_call({:admit_outbound, peer_sid, peer_info}, _from, state) do
    pins = parent_pins(state)

    if peer_sid == state.parent_sid and not MapSet.member?(state.disabled_edges, peer_sid) and
         TLS.pin_allowed?(peer_info[:certfp] || peer_info["certfp"], pins),
       do: {:reply, :ok, state},
       else: {:reply, {:error, :peer_certificate_not_pinned}, state}
  end

  def handle_call({:register_session, _session, _metadata}, _from, %{lifecycle: :closing} = state),
    do: {:reply, {:error, :shutting_down}, state}

  def handle_call({:register_session, session, metadata}, _from, state) do
    peer_sid = metadata[:peer_sid] || metadata["peer_sid"]

    cond do
      not is_pid(session) or not Identity.valid_sid?(peer_sid) ->
        {:reply, {:error, :invalid_session_identity}, state}

      not direct_neighbor?(state, peer_sid) ->
        {:reply, {:error, :unconfigured_neighbor}, state}

      MapSet.member?(state.disabled_edges, peer_sid) ->
        {:reply, {:error, :edge_disabled}, state}

      Map.has_key?(state.sessions_by_peer, peer_sid) ->
        {:reply, {:error, :duplicate_edge}, state}

      true ->
        record = %{
          peer_sid: peer_sid,
          direction: metadata[:direction] || metadata["direction"],
          peer_name: metadata[:peer_name] || metadata["peer_name"],
          peer_info: metadata[:peer_info] || metadata["peer_info"],
          owner: metadata[:owner] || metadata["owner"],
          generation: metadata[:generation] || metadata["generation"] || Identity.nonce(),
          local_hello: metadata[:local_hello] || metadata["local_hello"] || state.local_hello,
          status: :hello,
          edge_id: nil,
          remote_hello: nil,
          outgoing_sync: nil,
          incoming_sync: nil,
          incoming_applied?: false,
          pending_state: [],
          pending_state_bytes: 0,
          pending: [],
          pending_bytes: 0
        }

        next = %{
          state
          | sessions: Map.put(state.sessions, session, record),
            sessions_by_peer: Map.put(state.sessions_by_peer, peer_sid, session)
        }

        {:reply, {:ok, record.generation}, next}
    end
  end

  def handle_call({:admit_hello, session, frame}, _from, state) do
    if state.lifecycle == :closing do
      {:reply, {:error, :shutting_down}, state}
    else
      case state.sessions[session] do
        nil ->
          {:reply, {:error, :unknown_session}, state}

        record ->
          case accept_hello(state, record, frame) do
            {:ok, next_state, _edge_id} -> {:reply, :ok, next_state}
            {:error, _} = error -> {:reply, error, state}
          end
      end
    end
  end

  def handle_call({:publish_row, row}, _from, state) do
    if state.lifecycle == :closing do
      {:reply, {:error, :shutting_down}, state}
    else
      case publish_local_rows(state, [row]) do
        {:ok, next} -> {:reply, :ok, next}
        {:error, _} = error -> {:reply, error, state}
      end
    end
  end

  def handle_call({:publish_member_status, channel, uid, join_id, mode, enabled, setter}, _from, state) do
    if state.lifecycle == :closing do
      {:reply, {:error, :shutting_down}, state}
    else
      case member_status_row(state, channel, uid, join_id, mode, enabled, setter) do
        {:ok, row} ->
          case publish_local_rows(state, [row]) do
            {:ok, next} -> {:reply, :ok, next}
            {:error, _} = error -> {:reply, error, state}
          end

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call({:publish_rows, rows}, _from, state) do
    if state.lifecycle == :closing do
      {:reply, {:error, :shutting_down}, state}
    else
      case publish_local_rows(state, rows) do
        {:ok, next} -> {:reply, :ok, next}
        {:error, _} = error -> {:reply, error, state}
      end
    end
  end

  def handle_call(:refresh_policy, _from, state) do
    if state.lifecycle == :closing do
      {:reply, {:error, :shutting_down}, state}
    else
      case refresh_local_policy(state) do
        {:ok, next} -> {:reply, :ok, next}
        {:error, _} = error -> {:reply, error, state}
      end
    end
  end

  def handle_call(:runtime_view, _from, state), do: {:reply, state.runtime, state}

  def handle_call({:publish_message, actor_uid, target, command, text, tags, request_id, options}, _from, state) do
    if state.lifecycle == :closing do
      {:reply, {:error, :shutting_down}, state}
    else
      request_id = message_request_id(command, target, request_id)

      case local_message_frame(state, actor_uid, target, command, text, tags, request_id) do
        {:ok, frame} ->
          next = put_message_waiter(state, frame, options)
          {:reply, :ok, route_origin_message(next, frame, options)}

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call(:status, _from, state) do
    {pending_link_frames, pending_link_bytes} = pending_link_queue_totals(state)
    {pending_sync_frames, pending_sync_bytes} = pending_sync_queue_totals(state)

    sessions =
      Enum.map(state.sessions, fn {pid, record} ->
        session_status =
          case session_queue_status(pid) do
            {:ok, queue} -> %{queue: queue}
            {:error, reason} -> %{queue: %{error: reason}}
          end

        {inspect(pid),
         Map.merge(Map.take(record, [:peer_sid, :direction, :status, :generation, :edge_id]), session_status)}
      end)

    {:reply,
     %{
       sid: state.runtime.sid,
       boot: state.runtime.boot,
       parent_sid: state.parent_sid,
       reachable_sids: MapSet.to_list(state.runtime.reachable_sids) |> Enum.sort(),
       sessions: sessions,
       pending_requests: map_size(state.requests.pending),
       pending_request_methods: pending_request_methods(state.requests),
       pending_messages: map_size(state.message_waiters),
       pending_sasl_attempts: map_size(state.sasl_attempts),
       pending_sasl_jobs: map_size(state.sasl_jobs),
       pending_repairs: map_size(state.channel_repairs),
       pending_policy_repairs: map_size(state.policy_repairs),
       pending_snapshot_jobs: map_size(state.sync_jobs),
       pending_link_frames: pending_link_frames,
       pending_link_bytes: pending_link_bytes,
       pending_sync_frames: pending_sync_frames,
       pending_sync_bytes: pending_sync_bytes,
       rehash_in_progress?: is_pid(state.rehash_pid),
       pending_output_groups: length(Output.pending_groups()),
       services_authority: state.runtime.services_authority,
       policy_epoch: state.runtime.policy.epoch,
       policy_revision: state.runtime.policy.revision,
       policy_ready?: ElixIRCd.Server.S2S.Policy.grant_ready?(state.runtime.policy),
       retry_blocked?: state.retry_blocked?,
       connector_error: state.connector_error,
       last_link_error: state.last_link_error,
       lifecycle: state.lifecycle
     }, state}
  end

  def handle_call(:shutdown, _from, state) do
    if state.lifecycle == :closing do
      {:reply, :ok, state}
    else
      {:reply, :ok, begin_shutdown(state)}
    end
  end

  def handle_call(:retry_parent, _from, state) do
    if state.lifecycle == :closing do
      {:reply, {:error, :shutting_down}, state}
    else
      state = %{
        state
        | retry_blocked?: false,
          reconnect_attempt: 0,
          disabled_edges: MapSet.delete(state.disabled_edges, state.parent_sid)
      }

      {:reply, :ok, schedule_parent(state, 0)}
    end
  end

  def handle_call({:connect_neighbor, target}, _from, state) do
    if state.lifecycle == :closing do
      {:reply, {:error, :shutting_down}, state}
    else
      case resolve_neighbor(state, target) do
        {:ok, sid} when sid == state.parent_sid ->
          next = %{
            state
            | disabled_edges: MapSet.delete(state.disabled_edges, sid),
              retry_blocked?: false,
              reconnect_attempt: 0
          }

          {:reply, {:ok, :connecting}, schedule_parent(next, 0)}

        {:ok, sid} ->
          {:reply, {:ok, :awaiting_child}, %{state | disabled_edges: MapSet.delete(state.disabled_edges, sid)}}

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call({:disable_neighbor, target, reason}, _from, state) do
    if state.lifecycle == :closing do
      {:reply, {:error, :shutting_down}, state}
    else
      case resolve_neighbor(state, target) do
        {:ok, sid} ->
          next = %{state | disabled_edges: MapSet.put(state.disabled_edges, sid)}
          next = if sid == state.parent_sid and next.parent_timer, do: cancel_parent_timer(next), else: next

          next =
            case next.sessions_by_peer[sid] do
              session when is_pid(session) ->
                record = next.sessions[session]
                if is_map(record), do: Session.close(session, "OPERATOR", safe_reason(reason))
                next

              _ ->
                next
            end

          if sid == state.parent_sid and is_pid(state.parent_connector) and Process.alive?(state.parent_connector),
            do: GenServer.stop(state.parent_connector, :normal)

          {:reply, :ok, next}

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call(:topology_links, _from, state) do
    reachable = state.runtime.reachable_sids

    links =
      state.roster
      |> Enum.filter(&MapSet.member?(reachable, &1.sid))
      |> Enum.map(fn row ->
        %{
          sid: row.sid,
          name: row.name,
          parent: row.parent,
          local?: row.sid == state.runtime.sid,
          reachable?: true
        }
      end)
      |> Enum.sort_by(& &1.sid)

    {:reply, links, state}
  end

  def handle_call({:request, target_sid, actor, method, args, guards, ttl_ms}, _from, state) do
    originate_request_call(state, target_sid, actor, method, args, guards, ttl_ms, nil)
  end

  def handle_call({:request_with_reply, target_sid, actor, method, args, guards, waiter, ttl_ms}, _from, state) do
    originate_request_call(state, target_sid, actor, method, args, guards, ttl_ms, waiter)
  end

  def handle_call({:request_with_reply_context, target_sid, actor, method, args, guards, waiter, ttl_ms}, _from, state) do
    originate_request_call(state, target_sid, actor, method, args, guards, ttl_ms, waiter)
  end

  defp pending_request_methods(%{pending: pending}) do
    pending
    |> Enum.map(fn
      {_key, %{frame: %{"method" => method}}} when is_binary(method) -> method
      _ -> "unknown"
    end)
    |> Enum.frequencies()
  end

  defp originate_request_call(state, target_sid, actor, method, args, guards, ttl_ms, waiter) do
    if state.lifecycle == :closing do
      {:reply, {:error, :shutting_down}, state}
    else
      with {:ok, target} <- request_target(state, target_sid),
           true <- target_sid == target["sid"],
           {:ok, request_id, next} <- originate_request(state, target, actor, method, args, guards, ttl_ms, waiter) do
        {:reply, {:ok, request_id}, next}
      else
        false -> {:reply, {:error, :invalid_request_target}, state}
        {:error, _} = error -> {:reply, error, state}
      end
    end
  end

  @impl true
  def handle_info(
        {:s2s_session_event, _session, _generation, _event, _owner, _peer_info},
        %{lifecycle: :closing} = state
      ),
      do: {:noreply, state}

  def handle_info(
        {:s2s_session_event, _session, _generation, _event, owner, _peer_info, delivery_ref},
        %{lifecycle: :closing} = state
      ) do
    send(owner, {:s2s_manager_event_ack, delivery_ref, :closing})
    {:noreply, state}
  end

  def handle_info(
        {:s2s_session_event, session, generation, event, owner, peer_info, delivery_ref},
        state
      ) do
    case state.sessions[session] do
      %{generation: ^generation, owner: ^owner, peer_info: ^peer_info} = record ->
        result = handle_session_event(state, session, record, event)
        send(owner, {:s2s_manager_event_ack, delivery_ref, :ok})
        result

      _ ->
        send(owner, {:s2s_manager_event_ack, delivery_ref, :stale})
        {:noreply, state}
    end
  end

  def handle_info({:s2s_session_event, session, generation, event, _owner, _peer_info}, state) do
    case state.sessions[session] do
      %{generation: ^generation} = record -> handle_session_event(state, session, record, event)
      _ -> {:noreply, state}
    end
  end

  def handle_info({:s2s_session_event, _session, _event}, %{lifecycle: :closing} = state), do: {:noreply, state}

  def handle_info({:s2s_session_event, session, event}, state) do
    case state.sessions[session] do
      record when is_map(record) -> handle_session_event(state, session, record, event)
      _ -> {:noreply, state}
    end
  end

  def handle_info({:s2s_link_closed, session, reason}, state), do: {:noreply, cleanup_session(state, session, reason)}

  def handle_info({:s2s_cancel_recipient, recipient, uid}, state) do
    {:noreply, cancel_recipient_requests(state, recipient, uid)}
  end

  def handle_info({:s2s_cancel_sasl_attempt, recipient, uid, attempt_id}, state) do
    {:noreply, cancel_origin_sasl_requests(state, recipient, uid, attempt_id)}
  end

  def handle_info({:s2s_output_uncertain, group, reason}, state) do
    scope = output_destination_scope(group)
    _ = Output.fence_pending(scope)
    reason = safe_reason(reason)
    next = close_uncertain_link_generations(state, scope, "uncertain output: " <> reason)

    {:noreply, %{next | connector_error: "uncertain output: " <> reason, retry_blocked?: false, reconnect_attempt: 0}}
  end

  def handle_info({:s2s_sasl_result, job_ref, result}, state) do
    if state.lifecycle == :closing do
      {:noreply, state}
    else
      case Map.pop(state.sasl_jobs, job_ref) do
        {nil, _jobs} ->
          {:noreply, state}

        {job, jobs} ->
          next = %{state | sasl_jobs: jobs}
          finish_sasl_job(next, job, result)
      end
    end
  end

  def handle_info({:s2s_service_job_done, job_ref, result}, state) do
    if state.lifecycle == :closing do
      {:noreply, state}
    else
      case Map.pop(state.service_jobs, job_ref) do
        {nil, _jobs} ->
          {:noreply, state}

        {%{monitor_ref: monitor_ref} = job, jobs} ->
          if is_reference(monitor_ref), do: Process.demonitor(monitor_ref, [:flush])
          state = %{state | service_jobs: jobs}
          finish_service_job(state, job_ref, job, result)
      end
    end
  end

  def handle_info({:s2s_sync_job_done, job_ref, result}, state) do
    case Map.pop(state.sync_jobs, job_ref) do
      {nil, _sync_jobs} ->
        {:noreply, state}

      {%{monitor_ref: monitor_ref} = job, sync_jobs} ->
        if is_reference(monitor_ref), do: Process.demonitor(monitor_ref, [:flush])
        finish_sync_job(%{state | sync_jobs: sync_jobs}, job, result)
    end
  end

  def handle_info({:s2s_service_owner_reply, job_ref, result}, state) do
    if state.lifecycle == :closing do
      {:noreply, state}
    else
      case state.service_jobs[job_ref] do
        %{stage: :owner} = job ->
          state = %{state | service_jobs: Map.delete(state.service_jobs, job_ref)}
          finish_service_owner_reply(state, job, result)

        _ ->
          {:noreply, state}
      end
    end
  end

  def handle_info({:s2s_rehash_done, pid, result}, %{rehash_pid: pid} = state) do
    state = finish_rehash(state)

    if result != :ok do
      Logger.error("native S2S configuration reload failed")
    end

    {:noreply, state}
  end

  def handle_info({:s2s_rehash_done, _pid, _result}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    if state.lifecycle == :closing do
      {:noreply, state}
    else
      cond do
        state.rehash_monitor == monitor_ref ->
          Logger.error("native S2S configuration reload worker stopped")
          {:noreply, finish_rehash(state)}

        true ->
          case Enum.find(state.service_jobs, fn {_job_ref, job} -> job.monitor_ref == monitor_ref end) do
            {job_ref, job} ->
              state = %{state | service_jobs: Map.delete(state.service_jobs, job_ref)}
              finish_service_job(state, job_ref, job, {:error, "REJECTED", safe_reason(reason)})

            nil ->
              case Enum.find(state.sync_jobs, fn {_job_ref, job} -> job.monitor_ref == monitor_ref end) do
                {job_ref, job} ->
                  next = %{state | sync_jobs: Map.delete(state.sync_jobs, job_ref)}
                  finish_sync_job(next, job, {:error, {:snapshot_worker, reason}})

                nil ->
                  {:noreply, state}
              end
          end
      end
    end
  end

  def handle_info({:s2s_connector_down, connector, reason}, %{parent_connector: connector} = state) do
    if state.lifecycle == :closing do
      {:noreply, %{state | parent_connector: nil, connector_error: safe_reason(reason)}}
    else
      next = cancel_stable_timer(%{state | parent_connector: nil, connector_error: safe_reason(reason)})

      if permanent_link_error?(reason),
        do: {:noreply, %{next | retry_blocked?: true}},
        else: {:noreply, schedule_parent(next, reconnect_delay(next, reason))}
    end
  end

  def handle_info({:s2s_connector_down, _connector, _reason}, state), do: {:noreply, state}

  def handle_info(:connect_parent, %{lifecycle: :closing} = state), do: {:noreply, state}
  def handle_info(:connect_parent, %{parent_sid: nil} = state), do: {:noreply, state}
  def handle_info(:connect_parent, %{retry_blocked?: true} = state), do: {:noreply, state}

  def handle_info(:connect_parent, state) do
    if MapSet.member?(state.disabled_edges, state.parent_sid), do: {:noreply, state}, else: connect_parent(state)
  end

  def handle_info({@stable_active_message, session, generation}, state) do
    case state.sessions[session] do
      %{generation: ^generation, status: :active, owner: owner} when owner == state.parent_connector ->
        {:noreply, %{cancel_stable_timer(state) | reconnect_attempt: 0}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(@heartbeat_message, state) do
    if state.lifecycle == :closing do
      {:noreply, state}
    else
      state =
        Enum.reduce(state.sessions, state, fn {session, record}, current ->
          if record.status == :active do
            _ =
              Session.ping(
                session,
                Identity.nonce(),
                value(section(current.s2s, :timeouts), :heartbeat_timeout_ms, 60_000)
              )
          end

          current
        end)

      timer = Process.send_after(self(), @heartbeat_message, state.heartbeat_ms)
      {:noreply, %{state | heartbeat_timer: timer}}
    end
  end

  def handle_info(@request_expiry_message, state) do
    if state.lifecycle == :closing do
      {:noreply, state}
    else
      now = Requests.monotonic_ms()
      {sasl_attempts, expired_attempts} = expire_sasl_attempts(state.sasl_attempts, now)

      state = %{state | sasl_attempts: sasl_attempts}
      state = expire_sasl_attempt_jobs(state, expired_attempts, now)
      {requests, expired} = Requests.expire(state.requests, now)
      sasl_jobs = cancel_expired_sasl_jobs(state.sasl_jobs, expired, state.sasl_pool)
      state = notify_expired_waiters(%{state | requests: requests, sasl_jobs: sasl_jobs}, expired)
      state = expire_message_waiters(state, Requests.monotonic_ms())
      Process.send_after(self(), @request_expiry_message, 1_000)
      {:noreply, state}
    end
  end

  def handle_info({:s2s_admin_lifecycle, action, reason}, %{lifecycle: :running} = state)
      when action in ~w(restart shutdown) do
    next = begin_shutdown(state, lifecycle_reason(action, reason))
    invoke_lifecycle(state, action, reason)
    {:noreply, next}
  end

  def handle_info(@finish_shutdown_message, %{lifecycle: :closing} = state), do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.heartbeat_timer, do: Process.cancel_timer(state.heartbeat_timer)
    if state.parent_timer, do: Process.cancel_timer(state.parent_timer)
    if state.stable_timer, do: Process.cancel_timer(state.stable_timer)
    if state.shutdown_timer, do: Process.cancel_timer(state.shutdown_timer)
    stop_service_jobs(state.service_jobs)
    stop_sync_jobs(state.sync_jobs)
    stop_rehash_job(state)
    _ = close_link_generations(state, "server shutdown")
    if is_pid(state.sasl_pool) and Process.alive?(state.sasl_pool), do: Pool.stop(state.sasl_pool)

    :ok
  end

  defp handle_session_event(state, session, record, {:hello, _frame}) do
    start_sync(state, session, record)
  end

  defp handle_session_event(state, session, record, {:frame, frame, body}),
    do: handle_frame(state, session, record, frame, body)

  defp handle_session_event(state, session, record, {:frame, frame, body, received_at}),
    do: handle_frame_event(state, session, record, frame, body, received_at)

  defp handle_session_event(state, session, record, {:frame, frame}),
    do: handle_frame(state, session, record, frame, nil)

  defp handle_session_event(state, session, _record, :active) do
    next_record = Map.put(state.sessions[session], :status, :active)
    state = if next_record.owner == state.parent_connector, do: %{state | connector_error: nil}, else: state
    next = put_session(state, session, next_record)
    next = mark_edge_ready(next, session, next_record)
    next = release_blocked_channel_repairs(next)
    next = schedule_stable_reset(next, session, next_record)
    next = broadcast_frame(next, topology_state_frame(next), nil)
    {:noreply, flush_pending(next, session)}
  end

  defp handle_session_event(state, session, _record, {:send_error, reason}),
    do: {:noreply, cleanup_session(state, session, {:send_error, reason})}

  defp handle_session_event(state, session, _record, {:close, reason}),
    do: {:noreply, cleanup_session(state, session, {:peer_close, reason})}

  defp handle_session_event(state, _session, _record, _event), do: {:noreply, state}

  defp handle_frame_event(state, session, record, %{"t" => "request"} = frame, body, received_at),
    do: handle_frame(state, session, record, frame, body, received_at)

  defp handle_frame_event(state, session, record, frame, body, _received_at),
    do: handle_frame(state, session, record, frame, body)

  defp handle_frame(state, session, record, %{"t" => "sync"} = frame, body) do
    case handle_sync(state, session, record, frame, body) do
      {:ok, next} ->
        {:noreply, next}

      {:error, reason, next} ->
        Session.close(session, "DEPENDENCY", safe_reason(reason))
        {:noreply, cleanup_session(next, session, reason)}
    end
  end

  defp handle_frame(state, session, record, %{"t" => "state"} = frame, _body) do
    if ingress_origin_allowed?(state, record, frame) do
      if record.incoming_applied? do
        case apply_state_frame(state, session, record, frame) do
          {:ok, next} ->
            {:noreply, next}

          {:deferred, next} ->
            {:noreply, next}

          {:error, reason, next} ->
            Session.close(session, "ORIGIN", safe_reason(reason))
            {:noreply, cleanup_session(next, session, reason)}
        end
      else
        {:noreply, queue_state_frame(state, session, record, frame)}
      end
    else
      Session.close(session, "ORIGIN", "origin route is not authenticated")
      {:noreply, cleanup_session(state, session, :origin_route)}
    end
  end

  defp handle_frame(state, session, record, %{"t" => "message"} = frame, _body) do
    cond do
      not ingress_origin_allowed?(state, record, frame) ->
        Session.close(session, "ORIGIN", "origin route is not authenticated")
        {:noreply, cleanup_session(state, session, :origin_route)}

      record.status == :active ->
        {:noreply, route_message(state, session, record, frame)}

      true ->
        {:noreply, state}
    end
  end

  defp handle_frame(state, session, record, %{"t" => "request"} = frame, _body),
    do: handle_request(state, session, record, frame, nil)

  defp handle_frame(state, session, record, %{"t" => "reply"} = frame, _body) do
    if ingress_origin_allowed?(state, record, frame) do
      {:noreply, route_frame(state, session, frame)}
    else
      Session.close(session, "ORIGIN", "origin route is not authenticated")
      {:noreply, cleanup_session(state, session, :origin_route)}
    end
  end

  defp handle_frame(state, _session, _record, _frame, _body), do: {:noreply, state}

  defp handle_frame(state, session, record, %{"t" => "request"} = frame, _body, received_at),
    do: handle_request(state, session, record, frame, received_at)

  defp handle_request(state, session, record, frame, received_at) do
    cond do
      not ingress_origin_allowed?(state, record, frame) ->
        Session.close(session, "ORIGIN", "origin route is not authenticated")
        {:noreply, cleanup_session(state, session, :origin_route)}

      record.status == :active ->
        case request_with_remaining_ttl(frame, received_at) do
          {:ok, frame} ->
            handle_request_for_active(state, session, record, frame)

          :expired ->
            {:noreply, route_request_timeout(state, session, frame)}
        end

      true ->
        {:noreply, state}
    end
  end

  defp request_with_remaining_ttl(frame, received_at) when is_integer(received_at) do
    elapsed = max(Requests.monotonic_ms() - received_at, 0)
    remaining = frame["ttl_ms"] - elapsed

    if remaining > 0, do: {:ok, Map.put(frame, "ttl_ms", remaining)}, else: :expired
  end

  defp request_with_remaining_ttl(frame, _received_at), do: {:ok, frame}

  defp route_request_timeout(state, session, frame) do
    payload = Requests.error_payload("TIMEOUT", "request expired in transit")

    case Requests.build_reply_from_request(frame, "TIMEOUT", payload, 0, true, 1) do
      {:ok, reply} -> route_frame(state, session, reply)
      {:error, _reason} -> state
    end
  end

  defp handle_request_for_active(state, session, record, frame) do
    if frame["to"] != %{"sid" => state.runtime.sid, "boot" => state.runtime.boot} do
      {:noreply, route_frame(state, session, frame)}
    else
      now = Requests.monotonic_ms()

      case Requests.admit(state.requests, frame, now) do
        {:ok, requests, _pending} ->
          execute_admitted_request(state, session, record, frame, requests, now)

        {:duplicate, _requests, %{status: status, payload: {:stream, parts}}} ->
          {:noreply, send_stream_replies(state, session, frame, status, parts)}

        {:duplicate, _requests, %{status: status, payload: payload}} ->
          case Requests.build_reply_from_request(frame, status, payload, 0, true, 1) do
            {:ok, reply} -> {:noreply, route_frame(state, session, reply)}
            _ -> {:noreply, state}
          end

        {:duplicate_pending, _requests} ->
          {:noreply, state}

        {:error, reason} ->
          state = cleanup_rejected_sasl_request(state, frame, reason)
          {status, message} = request_admission_failure(reason)
          payload = Requests.failure_payload(frame, status, message)

          case Requests.build_reply_from_request(frame, status, payload, 0, true, 1) do
            {:ok, reply} -> {:noreply, route_frame(state, session, reply)}
            {:error, _reason} -> {:noreply, state}
          end
      end
    end
  end

  defp request_admission_failure(:request_capacity),
    do: {"RESOURCE", "request capacity is exhausted"}

  defp request_admission_failure(:request_origin_capacity),
    do: {"RESOURCE", "request origin capacity is exhausted"}

  defp request_admission_failure(:request_id_conflict),
    do: {"REJECTED", "request ID conflicts with an existing request"}

  defp request_admission_failure(_reason),
    do: {"REJECTED", "request cannot be admitted"}

  defp cleanup_rejected_sasl_request(state, %{"method" => "sasl", "args" => args}, reason)
       when reason in [:request_capacity, :request_origin_capacity] and is_map(args) do
    key = {args["uid"], args["attempt_id"]}

    if Map.has_key?(state.sasl_attempts, key),
      do: cancel_sasl_attempt(state, key, nil),
      else: state
  end

  defp cleanup_rejected_sasl_request(state, _frame, _reason), do: state

  defp ingress_origin_allowed?(state, record, %{"origin" => %{"sid" => sid, "boot" => boot}} = frame) do
    current? = node_ref_current?(state, sid, boot)
    direct? = sid == record.peer_sid and get_in(record.remote_hello || %{}, ["boot"]) == boot

    routed? =
      sid != state.runtime.sid and
        match?(
          {:ok, [_local, peer_sid | _]} when peer_sid == record.peer_sid,
          Tree.active_route(state.roster, state.runtime.sid, sid, state.runtime.active_edges)
        )

    topology_bootstrap? =
      sid != state.runtime.sid and
        Runtime.topology_bootstrap_origin_allowed?(
          state.runtime,
          %{"sid" => sid, "boot" => boot},
          record.peer_sid,
          frame["changes"]
        )

    merge_bootstrap? = merge_bootstrap_origin_allowed?(state, record, sid, boot, frame)
    allowed? = direct? or (current? and routed?) or topology_bootstrap? or merge_bootstrap?

    allowed?
  end

  defp ingress_origin_allowed?(_state, _record, _frame), do: false

  defp merge_bootstrap_origin_allowed?(state, record, sid, boot, %{
         "t" => "state",
         "context" => %{"kind" => "merge"},
         "changes" => changes
       })
       when is_binary(sid) and is_binary(boot) and is_list(changes) and changes != [] do
    static_route? =
      match?(
        {:ok, [local_sid, peer_sid | _]}
        when local_sid == state.runtime.sid and peer_sid == record.peer_sid,
        Tree.path(state.roster, state.runtime.sid, sid)
      )

    Identity.valid_sid?(sid) and Identity.valid_id?(boot) and static_route? and
      (not Map.has_key?(state.runtime.nodes, sid) or node_ref_current?(state, sid, boot))
  end

  defp merge_bootstrap_origin_allowed?(_state, _record, _sid, _boot, _frame), do: false

  defp handle_sync(state, session, record, %{"phase" => "begin", "sync_id" => sync_id} = frame, _body) do
    if record.incoming_sync do
      {:error, :duplicate_snapshot, state}
    else
      staging =
        Sync.new_staging(sync_id,
          max_rows: 65_536,
          max_bytes: value(section(state.s2s, :budgets), :snapshot_staging_bytes, 128 * 1_048_576)
        )

      case Sync.stage(staging, frame, nil) do
        {:ok, staging} -> {:ok, put_session(state, session, %{record | incoming_sync: staging})}
        {:error, reason} -> {:error, reason, state}
      end
    end
  end

  defp handle_sync(state, session, record, %{"phase" => "rows"} = frame, body) do
    case record.incoming_sync do
      nil ->
        {:error, :snapshot_begin_missing, state}

      staging ->
        case Sync.stage(staging, frame, body) do
          {:ok, next_staging} -> {:ok, put_session(state, session, %{record | incoming_sync: next_staging})}
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  defp handle_sync(state, session, record, %{"phase" => "end", "sync_id" => sync_id} = frame, _body) do
    with %{sync_id: ^sync_id} = staging <- record.incoming_sync,
         {:ok, result} <- Sync.finish(staging, frame),
         origin <- %{"sid" => record.peer_sid, "boot" => record.remote_hello["boot"]},
         {:ok, next} <- apply_incoming_snapshot(state, session, record, result.rows, origin),
         {:ok, ack} <- Sync.ack(sync_id, 1, result.digest),
         :ok <- Session.enqueue_frame(session, ack) do
      Session.mark_sync(session, :applied)

      next =
        put_session(next, session, %{record | incoming_sync: nil, incoming_applied?: true})
        |> flush_pending_state(session)

      {:ok, next}
    else
      nil -> {:error, :snapshot_begin_missing, state}
      {:error, reason, next} when is_map(next) -> {:error, reason, next}
      {:error, reason} -> {:error, reason, state}
      _ -> {:error, :snapshot_apply_failed, state}
    end
  end

  defp handle_sync(state, session, record, %{"phase" => "ack", "sync_id" => sync_id, "sha256" => digest}, _body) do
    case record.outgoing_sync do
      %{sync_id: ^sync_id, digest: ^digest} ->
        Session.mark_sync(session, :acknowledged)
        {:ok, put_session(state, session, %{record | outgoing_sync: nil})}

      _ ->
        {:error, :unexpected_snapshot_ack, state}
    end
  end

  defp handle_sync(state, _session, _record, _frame, _body), do: {:error, :invalid_snapshot_phase, state}

  defp apply_incoming_snapshot(state, session, record, rows, origin) do
    previous_runtime = state.runtime
    old_capability_maps = capture_dynamic_capabilities(previous_runtime)
    merge_id = Identity.nonce()
    context = %{"kind" => "merge", "id" => merge_id}
    via = %{"sid" => record.peer_sid, "boot" => record.remote_hello["boot"]}
    begin = %{"kind" => "merge.begin", "id" => merge_id, "via" => via}
    finish = %{"kind" => "merge.end", "id" => merge_id}
    abort = %{"kind" => "merge.abort", "id" => merge_id}

    case Runtime.apply_local_row(state.runtime, begin) do
      {:ok, runtime, effects} ->
        state = %{state | runtime: runtime}

        with {:ok, state} <- apply_runtime_effects(state, effects, suppress_c2s: true),
             state <-
               broadcast_frame(
                 state,
                 merge_state_frame(state, [begin], local_origin(state), %{"kind" => "live"}),
                 session
               ),
             {:ok, runtime, effects} <-
               Runtime.apply_snapshot_rows(state.runtime, rows, origin, context,
                 source_sid: record.peer_sid,
                 snapshot: true,
                 preserve_local_edges: true
               ),
             {:ok, state} <- apply_runtime_effects(%{state | runtime: runtime}, effects, suppress_c2s: true),
             state <- maybe_notify_dynamic_capabilities(state, previous_runtime, old_capability_maps),
             state <- publish_merge_rows(state, session, rows, context, origin),
             {:ok, runtime, effects} <- Runtime.apply_local_row(state.runtime, finish),
             {:ok, state} <- apply_runtime_effects(%{state | runtime: runtime}, effects, suppress_c2s: true) do
          {:ok,
           broadcast_frame(state, merge_state_frame(state, [finish], local_origin(state), %{"kind" => "live"}), session)}
        else
          {:error, reason} ->
            {:error, reason, abort_incoming_snapshot(state, session, abort)}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp abort_incoming_snapshot(state, session, abort) do
    case Runtime.apply_local_row(state.runtime, abort) do
      {:ok, runtime, effects} ->
        state = %{state | runtime: runtime}

        case apply_runtime_effects(state, effects, suppress_c2s: true) do
          {:ok, state} ->
            broadcast_frame(state, merge_state_frame(state, [abort], local_origin(state), %{"kind" => "live"}), session)

          {:error, _reason} ->
            broadcast_frame(state, merge_state_frame(state, [abort], local_origin(state), %{"kind" => "live"}), session)
        end

      {:error, _reason} ->
        state
    end
  end

  defp publish_merge_rows(state, session, rows, context, fallback_origin) do
    rows
    |> merge_row_groups(state, fallback_origin)
    |> Enum.reduce(state, fn {origin, group}, current ->
      broadcast_frame(current, merge_state_frame(current, group, origin, context), session)
    end)
  end

  defp merge_row_groups(rows, state, fallback_origin) do
    rows
    |> Enum.reduce([], fn row, groups ->
      origin = merge_row_origin(state, row, fallback_origin)

      case groups do
        [{^origin, current} | rest] when length(current) < 256 -> [{origin, current ++ [row]} | rest]
        _ -> [{origin, [row]} | groups]
      end
    end)
    |> Enum.reverse()
  end

  defp merge_row_origin(state, %{"kind" => kind, "user" => %{"home" => home}}, fallback_origin)
       when kind == "user.put",
       do: known_node_ref(state, home, fallback_origin)

  defp merge_row_origin(state, %{"kind" => "memberships.put", "home" => home}, fallback_origin),
    do: known_node_ref(state, home, fallback_origin)

  defp merge_row_origin(state, %{"kind" => "user.quit", "home" => home}, fallback_origin),
    do: known_node_ref(state, home, fallback_origin)

  defp merge_row_origin(state, %{"kind" => "invite.notice", "target_uid" => uid}, fallback_origin) do
    case state.runtime.users[uid] do
      %{"home" => home} -> known_node_ref(state, home, fallback_origin)
      _ -> fallback_origin
    end
  end

  defp merge_row_origin(state, %{"kind" => kind}, fallback_origin)
       when kind in ["policy.change", "policy.cache.begin", "policy.cache.rows", "policy.cache.end"] do
    authority = state.runtime.services_authority

    case state.runtime.nodes[authority] do
      %{"sid" => ^authority, "boot" => boot} -> %{"sid" => authority, "boot" => boot}
      _ -> fallback_origin
    end
  end

  defp merge_row_origin(state, %{"kind" => kind, "stamp" => [_, sid, boot]}, fallback_origin)
       when kind in ["channel.field", "channel.list", "member.status"] do
    known_node_ref(state, %{"sid" => sid, "boot" => boot}, fallback_origin)
  end

  defp merge_row_origin(_state, _row, fallback_origin), do: fallback_origin

  defp known_node_ref(state, %{"sid" => sid, "boot" => boot}, fallback_origin) do
    case state.runtime.nodes[sid] do
      %{"boot" => ^boot} -> %{"sid" => sid, "boot" => boot}
      _ -> fallback_origin
    end
  end

  defp merge_state_frame(state, rows, origin, context) do
    %{
      "t" => "state",
      "n" => 1,
      "origin" => origin_ref(state, origin),
      "actor" => %{"server" => origin_ref(state, origin)["sid"]},
      "context" => context,
      "changes" => rows
    }
  end

  defp origin_ref(state, %{"sid" => sid, "boot" => boot} = origin) do
    if sid == state.runtime.sid and boot == state.runtime.boot, do: origin, else: known_node_ref(state, origin, origin)
  end

  defp local_origin(state), do: %{"sid" => state.runtime.sid, "boot" => state.runtime.boot}

  defp start_sync(state, session, record) do
    if not is_nil(record.outgoing_sync) or sync_job_for?(state, session, record.generation) do
      {:noreply, state}
    else
      {state, record} = discard_pre_snapshot_output(state, session, record)
      cut = state.output_cut + 1
      sync_ref = make_ref()
      manager = self()
      runtime = state.runtime
      capture_fun = state.sync_capture_fun
      start_n = session_send_n(session)

      {pid, monitor_ref} =
        spawn_monitor(fn ->
          result = prepare_sync(runtime, cut, start_n, capture_fun)
          send(manager, {:s2s_sync_job_done, sync_ref, result})
        end)

      job = %{
        session: session,
        generation: record.generation,
        pid: pid,
        monitor_ref: monitor_ref,
        cut: cut
      }

      {:noreply, %{state | output_cut: cut, sync_jobs: Map.put(state.sync_jobs, sync_ref, job)}}
    end
  end

  defp prepare_sync(runtime, cut, start_n, capture_fun) do
    projections = Runtime.export_projections(runtime)

    with {:ok, snapshot} <- capture_fun.(Identity.nonce(), cut, projections),
         {:ok, %{frames: frames, digest: digest}} <- Sync.frames(snapshot, start_n) do
      {:ok, snapshot.sync_id, digest, frames}
    end
  rescue
    error -> {:error, {:snapshot_worker, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:snapshot_worker, {kind, reason}}}
  end

  defp finish_sync_job(state, %{session: session, generation: generation}, {:ok, sync_id, digest, frames}) do
    case state.sessions[session] do
      %{generation: ^generation} = record ->
        case send_frames(session, frames) do
          :ok ->
            Session.mark_sync(session, :sent)
            next_record = %{record | outgoing_sync: %{sync_id: sync_id, digest: digest}, status: :syncing}
            next = put_session(state, session, next_record)
            {:noreply, flush_pending(next, session)}

          {:error, reason} ->
            Session.close(session, "RESOURCE", safe_reason(reason))
            {:noreply, cleanup_session(state, session, reason)}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp finish_sync_job(state, %{session: session, generation: generation}, {:error, reason}) do
    case state.sessions[session] do
      %{generation: ^generation} ->
        Session.close(session, "SCHEMA", safe_reason(reason))
        {:noreply, cleanup_session(state, session, reason)}

      _ ->
        {:noreply, state}
    end
  end

  defp finish_sync_job(state, _job, _result), do: {:noreply, state}

  defp sync_job_for?(state, session, generation) do
    Enum.any?(state.sync_jobs, fn {_ref, job} -> job.session == session and job.generation == generation end)
  end

  # The snapshot is a complete image at `cut`. Do not replay chat that predates
  # it, or live rows already represented by that image, after the snapshot.
  # Keep ephemeral events and control rows because the snapshot cannot recreate
  # them (for example invite notices and merge boundaries).
  defp discard_pre_snapshot_output(state, session, record) do
    pending =
      Enum.flat_map(record.pending, fn frame ->
        case pending_after_snapshot(frame, state) do
          nil -> []
          retained -> [retained]
        end
      end)

    bytes = Enum.reduce(pending, 0, fn frame, total -> total + frame_budget_bytes(frame) end)
    record = %{record | pending: pending, pending_bytes: bytes}
    {put_session(state, session, record), record}
  end

  defp pending_after_snapshot(%{"t" => "message"}, _state), do: nil

  defp pending_after_snapshot(%{"t" => "state", "changes" => changes} = frame, state)
       when is_list(changes) do
    remaining = Enum.reject(changes, &snapshot_covers_row?(state, &1))
    if remaining == [], do: nil, else: Map.put(frame, "changes", remaining)
  end

  defp pending_after_snapshot(frame, _state), do: frame

  defp snapshot_covers_row?(_state, %{"kind" => kind})
       when kind in [
              "topology.add",
              "topology.ready",
              "topology.remove",
              "user.put",
              "user.quit",
              "memberships.put",
              "channel.ensure",
              "channel.field",
              "channel.list",
              "member.status"
            ],
       do: true

  defp snapshot_covers_row?(state, %{"kind" => "policy.change"}) do
    state.runtime.services_authority == state.runtime.sid and Policy.grant_ready?(state.runtime.policy)
  end

  defp snapshot_covers_row?(_state, _row), do: false

  defp send_frames(session, frames) do
    Enum.reduce_while(frames, :ok, fn frame, :ok ->
      case Session.enqueue_frame(session, frame) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp session_send_n(session) do
    case Session.state(session) do
      %{send_n: n} when is_integer(n) and n > 0 -> n
      _ -> 1
    end
  catch
    :exit, _ -> 1
  end

  defp session_queue_status(session) when is_pid(session) do
    case Session.state(session, 100) do
      %{
        outbound_frames: outbound_frames,
        outbound_bytes: outbound_bytes,
        max_outbound_frames: max_outbound_frames,
        max_outbound_bytes: max_outbound_bytes,
        input_buffer_bytes: input_buffer_bytes
      } ->
        {:ok,
         %{
           outbound_frames: outbound_frames,
           outbound_bytes: outbound_bytes,
           max_outbound_frames: max_outbound_frames,
           max_outbound_bytes: max_outbound_bytes,
           input_buffer_bytes: input_buffer_bytes
         }}

      _ ->
        {:error, :invalid_session_status}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp session_queue_status(_session), do: {:error, :invalid_session}

  defp publish_local_rows(state, rows) do
    previous_runtime = state.runtime
    old_capability_maps = capture_dynamic_capabilities(previous_runtime)

    with true <- is_list(rows) and rows != [] and length(rows) <= 256,
         :ok <-
           Enum.reduce_while(rows, :ok, fn row, :ok ->
             if Schema.validate_row(row) == :ok, do: {:cont, :ok}, else: {:halt, {:error, :invalid_publication_row}}
           end),
         {:ok, runtime, effects} <- Runtime.apply_local_rows(state.runtime, rows, local_owner: true),
         :ok <- Output.observe_stamps(stamps_from_rows(rows)),
         :ok <- persist_local_policy_revision(state, runtime),
         {:ok, state} <- apply_runtime_effects(%{state | runtime: runtime}, effects),
         state <- maybe_notify_dynamic_capabilities(state, previous_runtime, old_capability_maps) do
      frame = state_frame(state, rows)
      {:ok, broadcast_frame(%{state | output_cut: state.output_cut + 1}, frame, nil)}
    else
      false -> {:error, :invalid_publication_group}
      {:error, _} = error -> error
    end
  end

  defp persist_local_policy_revision(
         %{runtime: %{services_authority: authority, sid: sid}},
         %{policy: %{epoch: epoch, revision: revision}}
       )
       when is_binary(authority) and authority == sid do
    case PolicyStore.persist_revision(epoch, revision) do
      :ok -> :ok
      {:error, _} = error -> error
    end
  end

  defp persist_local_policy_revision(_state, _runtime), do: :ok

  defp refresh_local_policy(%{runtime: %{services_authority: authority, sid: sid}} = state)
       when is_binary(authority) and authority == sid do
    refreshed =
      Memento.transaction!(fn ->
        Policy.from_sources(
          state.runtime.policy.epoch,
          RegisteredNicks.get_all(),
          RegisteredChannels.get_all(),
          RegisteredChannelAccesses.get_all(),
          [],
          revision: state.runtime.policy.revision + 1
        )
      end)

    with {:ok, refreshed} <- refreshed,
         changes <- Policy.diff(state.runtime.policy, refreshed),
         true <- changes != [] do
      if length(changes) <= 256 do
        with :ok <- PolicyStore.persist_revision(state.runtime.policy.epoch, refreshed.revision),
             {:ok, next} <- publish_policy_revisions(state, [{changes, refreshed.revision}]) do
          {:ok, next}
        end
      else
        invalidate_row = %{
          "kind" => "policy.change",
          "epoch" => state.runtime.policy.epoch,
          "revision" => refreshed.revision,
          "changes" => nil
        }

        with :ok <- PolicyStore.persist_revision(state.runtime.policy.epoch, refreshed.revision),
             {:ok, invalidated} <- publish_local_rows(state, [invalidate_row]),
             {:ok, next} <- install_authority_policy(invalidated, refreshed) do
          {:ok, next}
        end
      end
    else
      false -> {:ok, state}
      {:error, _} = error -> error
    end
  rescue
    error -> {:error, {:policy_refresh_failed, Exception.message(error)}}
  end

  defp refresh_local_policy(state), do: {:ok, state}

  defp publish_policy_revisions(state, revisions) do
    Enum.reduce_while(revisions, {:ok, state}, fn {changes, revision}, {:ok, current} ->
      row = %{
        "kind" => "policy.change",
        "epoch" => current.runtime.policy.epoch,
        "revision" => revision,
        "changes" => changes
      }

      case publish_local_rows(current, [row]) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp install_authority_policy(state, policy) do
    with {:ok, payloads} <- Policy.image_payloads(policy, 256),
         rows <- Enum.map(payloads, &policy_cache_row/1),
         {:ok, runtime, effects} <-
           Runtime.apply_snapshot_rows(
             state.runtime,
             rows,
             local_origin(state),
             %{"kind" => "live"},
             source_sid: state.runtime.sid,
             snapshot: true
           ),
         {:ok, next} <- apply_runtime_effects(%{state | runtime: runtime}, effects) do
      {:ok, next}
    else
      {:error, _} = error -> error
    end
  end

  defp policy_cache_row(%{"snapshot" => "policy", "phase" => "begin"} = payload),
    do: Map.drop(payload, ["snapshot", "phase"]) |> Map.put("kind", "policy.cache.begin")

  defp policy_cache_row(%{"snapshot" => "policy", "phase" => "rows"} = payload),
    do: Map.drop(payload, ["snapshot", "phase"]) |> Map.put("kind", "policy.cache.rows")

  defp policy_cache_row(%{"snapshot" => "policy", "phase" => "end"} = payload),
    do: Map.drop(payload, ["snapshot", "phase"]) |> Map.put("kind", "policy.cache.end")

  defp member_status_row(state, channel_ref, uid, join_id, mode, enabled, setter)
       when mode in ["o", "v"] and is_map(channel_ref) do
    key = CaseMapping.normalize(channel_ref["name"] || "")
    channel = state.runtime.channels[key]
    membership = state.runtime.memberships[uid]

    with %{} = current <- channel,
         true <- current.ref == channel_ref,
         true <-
           is_map(membership) and
             Enum.any?(membership.entries, fn entry ->
               CaseMapping.normalize(entry["channel"] || "") == key and entry["join_id"] == join_id
             end),
         true <- is_map(state.runtime.users[setter]) do
      previous = get_in(current, [:statuses, {uid, join_id, mode}, :stamp])
      if is_list(previous), do: :ok = Output.observe_stamp(previous)
      stamp = Output.next_stamp(state.runtime.sid, state.runtime.boot)

      row = %{
        "kind" => "member.status",
        "channel" => channel_ref,
        "uid" => uid,
        "join_id" => join_id,
        "mode" => mode,
        "enabled" => enabled,
        "stamp" => stamp,
        "setter" => %{"user" => setter}
      }

      if Schema.validate_row(row) == :ok, do: {:ok, row}, else: {:error, :invalid_status_row}
    else
      nil -> {:error, :missing_channel}
      false -> {:error, :stale_member_status}
      _ -> {:error, :member_status_unavailable}
    end
  end

  defp member_status_row(_state, _channel_ref, _uid, _join_id, _mode, _enabled, _setter),
    do: {:error, :invalid_member_status}

  defp state_frame(state, row) when is_map(row), do: state_frame(state, [row])

  defp state_frame(state, rows) when is_list(rows) do
    %{
      "t" => "state",
      "n" => 1,
      "origin" => %{"sid" => state.runtime.sid, "boot" => state.runtime.boot},
      "actor" => %{"server" => state.runtime.sid},
      "context" => %{"kind" => "live"},
      "changes" => rows
    }
  end

  defp topology_state_frame(state) do
    topology = state.runtime |> Runtime.export_projections() |> Map.fetch!(:topology)
    state_frame(state, topology)
  end

  defp broadcast_frame(state, frame, excluded) do
    Enum.reduce(state.sessions, state, fn {session, record}, current ->
      if session == excluded do
        current
      else
        deliver_or_queue(current, session, record, frame)
      end
    end)
  end

  defp deliver_or_queue(state, session, record, frame) do
    cond do
      record.outgoing_sync != nil or record.status in [:hello, :syncing] ->
        queue_pending_frame(state, session, record, frame)

      record.status == :active ->
        case safe_send_frame(session, frame) do
          :ok -> state
          {:error, reason} -> cleanup_session(state, session, reason)
        end

      true ->
        state
    end
  end

  defp safe_send_frame(session, frame) do
    Session.enqueue_frame(session, frame)
  catch
    :exit, reason -> {:error, reason}
  end

  defp topology_frame?(%{"t" => "state", "changes" => changes}),
    do: topology_control_frame?(changes)

  defp topology_frame?(_frame), do: false

  defp topology_add_frame?(%{"t" => "state", "changes" => changes}) when is_list(changes) and changes != [] do
    Enum.all?(changes, &match?(%{"kind" => "topology.add"}, &1))
  end

  defp topology_add_frame?(_frame), do: false

  defp mark_active_edges(state) do
    Enum.reduce(state.sessions, state, fn {session, record}, current ->
      if record.status == :active, do: mark_edge_ready(current, session, record), else: current
    end)
  end

  defp topology_control_frame?(changes) when is_list(changes) and changes != [] do
    Enum.all?(changes, fn
      %{"kind" => kind} when kind in ["topology.add", "topology.ready"] -> true
      _ -> false
    end)
  end

  defp topology_control_frame?(_changes), do: false

  defp topology_ready_frame?(%{"changes" => changes}) when is_list(changes) and changes != [] do
    Enum.all?(changes, &match?(%{"kind" => "topology.ready"}, &1))
  end

  defp topology_ready_frame?(_frame), do: false

  defp flush_pending(state, session) do
    case state.sessions[session] do
      %{pending: pending} = record when pending != [] ->
        case send_frames(session, Enum.reverse(pending)) do
          :ok ->
            put_session(state, session, %{record | pending: [], pending_bytes: 0})

          {:error, reason} ->
            Session.close(session, "RESOURCE", safe_reason(reason))
            cleanup_session(state, session, reason)
        end

      _ ->
        state
    end
  end

  defp queue_pending_frame(state, session, record, frame) do
    frame_bytes = frame_budget_bytes(frame)
    budgets = section(state.s2s, :budgets)
    max_bytes = value(budgets, :per_link_queue_bytes, 16 * 1_048_576)
    max_rows = value(budgets, :max_pending_frames, 65_536)
    max_aggregate_bytes = value(budgets, :aggregate_pending_bytes, 128 * 1_048_576)
    max_aggregate_rows = value(budgets, :aggregate_pending_frames, 262_144)
    {aggregate_rows, aggregate_bytes} = pending_link_queue_totals(state)

    cond do
      length(record.pending) >= max_rows or record.pending_bytes + frame_bytes > max_bytes ->
        Session.close(session, "RESOURCE", "link output queue")
        cleanup_session(state, session, :link_output_queue)

      aggregate_rows >= max_aggregate_rows or aggregate_bytes + frame_bytes > max_aggregate_bytes ->
        Session.close(session, "RESOURCE", "aggregate link output queue")
        cleanup_session(state, session, :aggregate_link_output_queue)

      true ->
        put_session(state, session, %{
          record
          | pending: [frame | record.pending],
            pending_bytes: record.pending_bytes + frame_bytes
        })
    end
  end

  defp route_frame(state, source_session, frame) do
    with %{"sid" => destination, "boot" => boot} <- frame["to"],
         true <- node_ref_current?(state, destination, boot) do
      if destination == state.runtime.sid do
        handle_local_reply(state, source_session, frame)
      else
        case Tree.active_route(state.roster, state.runtime.sid, destination, state.runtime.active_edges) do
          {:ok, [_local, peer_sid | _]} -> send_to_peer(state, peer_sid, frame)
          _ -> state
        end
      end
    else
      _ -> state
    end
  end

  defp route_message(state, source_session, record, frame) do
    case Delivery.destination_sids(state.runtime, frame, record.peer_sid) do
      {:ok, destinations} ->
        Enum.reduce(destinations, state, fn destination, current ->
          if destination == current.runtime.sid,
            do: deliver_local(current, source_session, frame),
            else: route_to_destination(current, source_session, destination, frame)
        end)

      {:error, _reason} ->
        state
    end
  end

  defp route_origin_message(state, frame, options) do
    deliver_local? = Keyword.get(options, :deliver_local, true)

    case Delivery.destination_sids(state.runtime, frame) do
      {:ok, destinations} ->
        Enum.reduce(destinations, state, fn destination, current ->
          if destination == current.runtime.sid,
            do: if(deliver_local?, do: deliver_local(current, nil, frame), else: current),
            else: route_to_destination(current, nil, destination, frame)
        end)

      {:error, _reason} ->
        state
    end
  end

  defp route_to_destination(state, source_session, destination, frame) do
    source_peer = if is_pid(source_session), do: get_in(state.sessions, [source_session, :peer_sid]), else: nil

    case Tree.active_route(state.roster, state.runtime.sid, destination, state.runtime.active_edges) do
      {:ok, [_local, peer_sid | _]} when peer_sid != source_peer ->
        send_to_peer(state, peer_sid, frame)

      _ ->
        state
    end
  end

  defp local_message_frame(state, actor_uid, target, command, text, tags, request_id)
       when is_binary(actor_uid) and is_map(target) and is_binary(command) and is_map(tags) do
    frame = %{
      "t" => "message",
      "n" => 1,
      "origin" => %{"sid" => state.runtime.sid, "boot" => state.runtime.boot},
      "actor" => %{"user" => actor_uid},
      "message_id" => Identity.nonce(),
      "sent_ms" => max(Identity.now_ms(), 1),
      "target" => target,
      "command" => command,
      "text" => text,
      "tags" => tags,
      "request_id" => request_id
    }

    with :ok <- Schema.validate_frame(frame),
         {:ok, [destination | _]} <- Delivery.destination_sids(state.runtime, frame),
         true <- destination in MapSet.to_list(state.runtime.reachable_sids) do
      {:ok, frame}
    else
      {:ok, []} -> {:error, :message_target_unavailable}
      false -> {:error, :message_target_unreachable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp local_message_frame(_state, _actor_uid, _target, _command, _text, _tags, _request_id),
    do: {:error, :invalid_message_origin}

  defp message_request_id("PRIVMSG", %{"user" => _uid}, nil), do: Identity.nonce()
  defp message_request_id(_command, _target, request_id), do: request_id

  defp send_to_peer(state, peer_sid, frame) do
    case state.sessions_by_peer[peer_sid] do
      session when is_pid(session) ->
        with record when is_map(record) <- state.sessions[session],
             %{"boot" => boot} <- record.remote_hello,
             true <- node_ref_current?(state, peer_sid, boot) do
          deliver_or_queue(state, session, record, frame)
        else
          _ -> state
        end

      _ ->
        state
    end
  end

  defp node_ref_current?(state, sid, boot) do
    case state.runtime.nodes[sid] do
      %{"boot" => ^boot} -> true
      _ -> sid == state.runtime.sid and boot == state.runtime.boot
    end
  end

  defp deliver_local(state, source_session, frame) do
    result = if is_function(state.delivery_fun, 2), do: state.delivery_fun.(state.runtime, frame), else: :ok

    case result do
      :ok ->
        route_message_reply(state, source_session, frame, "OK", Requests.ok_payload(nil))

      {:error, {:message_rejected, items}} when is_list(items) ->
        route_message_reply(state, source_session, frame, "REJECTED", %{"items" => items})

      {:error, reason} ->
        if message_request?(frame),
          do:
            route_message_reply(
              state,
              source_session,
              frame,
              "UNAVAILABLE",
              Requests.error_payload("UNAVAILABLE", safe_reason(reason))
            ),
          else: state

      _ ->
        if message_request?(frame),
          do:
            route_message_reply(
              state,
              source_session,
              frame,
              "UNAVAILABLE",
              Requests.error_payload("UNAVAILABLE", "message delivery failed")
            ),
          else: state
    end
  rescue
    error ->
      if message_request?(frame),
        do:
          route_message_reply(
            state,
            source_session,
            frame,
            "UNAVAILABLE",
            Requests.error_payload("UNAVAILABLE", safe_reason(error))
          ),
        else: state
  end

  defp message_request?(%{"command" => "PRIVMSG", "request_id" => request_id}) when is_binary(request_id),
    do: true

  defp message_request?(_frame), do: false

  defp route_message_reply(state, _source_session, %{"request_id" => nil}, _status, _payload), do: state

  defp route_message_reply(state, _source_session, %{"request_id" => request_id}, _status, _payload)
       when not is_binary(request_id),
       do: state

  defp route_message_reply(state, source_session, frame, status, payload) do
    reply = %{
      "t" => "reply",
      "n" => 1,
      "origin" => %{"sid" => state.runtime.sid, "boot" => state.runtime.boot},
      "to" => frame["origin"],
      "request_id" => frame["request_id"],
      "part" => 0,
      "done" => true,
      "status" => status,
      "payload" => payload
    }

    if Schema.validate_frame(reply) == :ok, do: route_frame(state, source_session, reply), else: state
  end

  defp apply_state_frame(state, session, record, frame) do
    if policy_repair_pending?(state, record, frame) do
      case defer_policy_frame(state, session, record, frame) do
        {:ok, next} -> {:deferred, next}
        {:error, reason, next} -> {:error, reason, next}
      end
    else
      apply_state_frame_now(state, session, record, frame)
    end
  end

  defp apply_state_frame_now(state, session, record, frame) do
    snapshot? = get_in(frame, ["context", "kind"]) == "merge"
    previous_runtime = state.runtime
    old_capability_maps = capture_dynamic_capabilities(previous_runtime)

    case Runtime.apply_frame(state.runtime, frame,
           source_sid: record.peer_sid,
           snapshot: snapshot?
         ) do
      {:ok, runtime, effects} ->
        :ok = observe_frame_stamps(frame)

        with {:ok, state} <- apply_runtime_effects(%{state | runtime: runtime}, effects, suppress_c2s: snapshot?),
             {:ok, state} <- apply_remote_presence(state, previous_runtime, effects, snapshot?) do
          state = maybe_notify_dynamic_capabilities(state, previous_runtime, old_capability_maps)
          outgoing = if topology_add_frame?(frame), do: topology_state_frame(state), else: frame
          next = broadcast_frame(state, outgoing, session)
          next = if topology_add_frame?(frame), do: mark_active_edges(next), else: next
          next = if topology_frame?(frame), do: flush_pending_state(next, session), else: next

          with {:ok, next} <- begin_policy_repair_if_invalidated(next, session, record, effects),
               next <- release_blocked_channel_repairs(next),
               next <- release_policy_repairs(next) do
            {:ok, next}
          else
            {:error, reason, next} -> {:error, reason, next}
          end
        else
          {:error, reason} -> {:error, reason, state}
        end

      {:error, reason} ->
        cond do
          reason == :missing_channel ->
            case defer_missing_channel_frame(state, session, record, frame) do
              {:ok, next} -> {:deferred, next}
              {:drop, next} -> {:ok, next}
              {:error, repair_reason, next} -> {:error, repair_reason, next}
            end

          match?({:policy_revision_gap, _, _}, reason) ->
            case defer_policy_frame(state, session, record, frame) do
              {:ok, next} -> {:deferred, next}
              {:error, repair_reason, next} -> {:error, repair_reason, next}
            end

          reason == :unknown_edge and topology_ready_frame?(frame) ->
            {:deferred, queue_state_frame(state, session, record, frame)}

          true ->
            {:error, reason, state}
        end
    end
  end

  defp policy_repair_pending?(state, record, frame) do
    policy_frame?(frame) and
      Map.has_key?(
        state.policy_repairs,
        {state.runtime.services_authority, record.peer_sid, record.generation}
      )
  end

  defp begin_policy_repair_if_invalidated(state, session, record, effects) do
    if Enum.any?(effects, &policy_invalidation_effect?/1),
      do: start_policy_repair(state, session, record),
      else: {:ok, state}
  end

  defp policy_invalidation_effect?(%{kind: :policy, row: %{"changes" => nil}}), do: true
  defp policy_invalidation_effect?(_effect), do: false

  defp start_policy_repair(state, session, record) do
    authority = state.runtime.services_authority

    with authority when is_binary(authority) <- authority,
         {:ok, target} <- request_target(state, authority) do
      key = {authority, record.peer_sid, record.generation}

      case state.policy_repairs[key] do
        repair when is_map(repair) ->
          {:ok, state}

        nil ->
          repair =
            new_policy_repair(key, session, record, target, authority, %{}, 0)
            |> Map.put(:pending_frames, [])
            |> Map.put(:pending_bytes, 0)

          state = mark_policy_unready(%{state | policy_repairs: Map.put(state.policy_repairs, key, repair)})

          case maybe_start_policy_repair(state, key, repair) do
            {:ok, next} -> {:ok, next}
            {:error, reason, next} -> {:error, reason, next}
          end
      end
    else
      nil -> {:error, :services_authority_missing, state}
      {:error, reason} -> {:error, {:policy_repair_unavailable, reason}, state}
    end
  end

  defp defer_missing_channel_frame(state, session, record, frame) do
    with {:ok, channel_ref, uid} <- missing_channel_context(state, frame),
         {:ok, target_sid} <- channel_repair_target(state, record, uid),
         {:ok, target} <- repair_target_ref(state, target_sid, frame) do
      key = channel_repair_key(record, target_sid, channel_ref["name"], state.runtime.case_mapping)
      frame_bytes = frame_budget_bytes(frame)

      case state.channel_repairs[key] do
        repair when is_map(repair) ->
          case append_channel_repair_frame(state, key, repair, frame, frame_bytes) do
            {:ok, next} -> maybe_start_channel_repair(next, key, next.channel_repairs[key])
            other -> other
          end

        nil ->
          with :ok <- repair_capacity_available?(state, session, frame_bytes),
               repair <-
                 new_channel_repair(
                   key,
                   session,
                   record,
                   target,
                   target_sid,
                   channel_ref,
                   uid,
                   frame,
                   frame_bytes,
                   blocked_merge_id(state, frame)
                 ),
               staged <- %{state | channel_repairs: Map.put(state.channel_repairs, key, repair)},
               result <- maybe_start_channel_repair(staged, key, repair) do
            result
          else
            {:error, reason} ->
              {:error, {:channel_repair_start_failed, reason},
               %{state | channel_repairs: Map.delete(state.channel_repairs, key)}}
          end
      end
    else
      {:error, :target_unreachable} ->
        if is_binary(missing_channel_uid(frame)),
          do: {:drop, state},
          else: {:error, {:channel_repair_unavailable, :target_unreachable}, state}

      {:error, reason} ->
        {:error, {:channel_repair_unavailable, reason}, state}
    end
  end

  defp repair_target_ref(state, target_sid, frame) do
    if is_binary(blocked_merge_id(state, frame)) do
      case state.runtime.nodes[target_sid] do
        %{"sid" => ^target_sid, "boot" => boot} = node ->
          {:ok, %{"sid" => target_sid, "boot" => boot, "name" => node["name"]}}

        _ ->
          {:error, :target_unreachable}
      end
    else
      request_target(state, target_sid)
    end
  end

  defp blocked_merge_id(state, %{"context" => %{"kind" => "merge", "id" => id}})
       when is_binary(id) do
    if MapSet.member?(state.runtime.merge_contexts, id), do: id, else: nil
  end

  defp blocked_merge_id(_state, _frame), do: nil

  defp defer_policy_frame(state, session, record, frame) do
    with true <- policy_frame?(frame),
         authority when is_binary(authority) <- state.runtime.services_authority,
         {:ok, target} <- request_target(state, authority) do
      key = {authority, record.peer_sid, record.generation}
      frame_bytes = frame_budget_bytes(frame)

      case state.policy_repairs[key] do
        repair when is_map(repair) ->
          case append_policy_repair_frame(state, key, repair, frame, frame_bytes) do
            {:ok, next} -> maybe_start_policy_repair(next, key, next.policy_repairs[key])
            other -> other
          end

        nil ->
          with :ok <- policy_repair_capacity_available?(state, session, frame_bytes),
               repair <- new_policy_repair(key, session, record, target, authority, frame, frame_bytes),
               staged <- mark_policy_unready(%{state | policy_repairs: Map.put(state.policy_repairs, key, repair)}),
               result <- maybe_start_policy_repair(staged, key, repair) do
            result
          else
            {:error, reason} ->
              {:error, {:policy_repair_start_failed, reason},
               %{state | policy_repairs: Map.delete(state.policy_repairs, key)}}
          end
      end
    else
      false -> {:error, :invalid_policy_repair_frame, state}
      nil -> {:error, :services_authority_missing, state}
      {:error, reason} -> {:error, {:policy_repair_unavailable, reason}, state}
    end
  end

  defp policy_frame?(%{"changes" => changes}) when is_list(changes),
    do: Enum.any?(changes, &(&1["kind"] == "policy.change"))

  defp policy_frame?(_frame), do: false

  defp mark_policy_unready(state) do
    policy = %{state.runtime.policy | ready?: false}
    %{state | runtime: %{state.runtime | policy: policy}}
  end

  defp new_policy_repair(key, session, record, target, authority, frame, frame_bytes) do
    %{
      key: key,
      session: session,
      peer_sid: record.peer_sid,
      generation: record.generation,
      target_sid: authority,
      target_ref: Map.take(target, ["sid", "boot"]),
      request_id: nil,
      phase: :begin,
      begin: nil,
      objects: [],
      pending_frames: [frame],
      pending_bytes: frame_bytes,
      expected_objects: nil,
      revision: nil,
      epoch: nil
    }
  end

  defp append_policy_repair_frame(state, key, repair, frame, frame_bytes) do
    budgets = section(state.s2s, :budgets)
    max_rows = value(budgets, :max_snapshot_delta_rows, 65_536)
    max_bytes = value(budgets, :snapshot_delta_queue_bytes, 16 * 1_048_576)

    cond do
      length(repair.pending_frames) >= max_rows or repair.pending_bytes + frame_bytes > max_bytes ->
        {:error, :policy_repair_queue}

      repair_bytes_for_session(state, repair.session) + frame_bytes > max_bytes ->
        {:error, :policy_repair_aggregate_queue}

      true ->
        next =
          put_in(state.policy_repairs[key], %{
            repair
            | pending_frames: [frame | repair.pending_frames],
              pending_bytes: repair.pending_bytes + frame_bytes
          })

        {:ok, next}
    end
  end

  defp policy_repair_capacity_available?(state, session, frame_bytes) do
    budgets = section(state.s2s, :budgets)
    max_repairs = value(budgets, :max_repairs, 16)
    max_bytes = value(budgets, :snapshot_delta_queue_bytes, 16 * 1_048_576)

    cond do
      repair_count(state) >= max_repairs ->
        {:error, :repair_capacity}

      repair_bytes_for_session(state, session) + frame_bytes > max_bytes ->
        {:error, :repair_aggregate_queue}

      true ->
        :ok
    end
  end

  defp repair_count(state), do: map_size(state.channel_repairs) + map_size(state.policy_repairs)

  defp maybe_start_policy_repair(state, key, repair) do
    if is_binary(repair.request_id) do
      {:ok, state}
    else
      case request_target(state, repair.target_sid) do
        {:ok, target} ->
          if target["boot"] == repair.target_ref["boot"] do
            case originate_request(
                   state,
                   target,
                   %{"server" => state.runtime.sid},
                   "snapshot",
                   %{"scope" => "policy", "channel" => nil, "for_uid" => nil},
                   repair_guards(),
                   repair_ttl_ms(state),
                   {:policy_repair, key}
                 ) do
              {:ok, request_id, next} ->
                next =
                  case next.policy_repairs[key] do
                    nil -> next
                    current -> put_in(next.policy_repairs[key], %{current | request_id: request_id})
                  end

                {:ok, next}

              {:error, reason} ->
                {:error, {:policy_repair_start_failed, reason}, state}
            end
          else
            {:error, :policy_authority_generation_changed, state}
          end

        {:error, reason} ->
          {:error, {:policy_repair_unavailable, reason}, state}
      end
    end
  end

  defp release_policy_repairs(state) do
    Enum.reduce(state.policy_repairs, state, fn {key, repair}, current ->
      case maybe_start_policy_repair(current, key, repair) do
        {:ok, next} -> next
        {:error, reason, next} -> fail_policy_repair(next, key, reason)
      end
    end)
  end

  defp missing_channel_context(state, %{"changes" => changes}) when is_list(changes) do
    ensured =
      changes
      |> Enum.filter(&(&1["kind"] == "channel.ensure"))
      |> Enum.map(&CaseMapping.normalize(get_in(&1, ["channel", "name"]) || ""))
      |> MapSet.new()

    Enum.find_value(changes, {:error, :missing_channel_context}, fn
      %{"kind" => kind, "channel" => %{"name" => name} = channel} = row
      when kind in ["channel.field", "channel.list", "member.status"] ->
        key = CaseMapping.normalize(name)

        if not Map.has_key?(state.runtime.channels, key) and not MapSet.member?(ensured, key),
          do: {:ok, channel, if(kind == "member.status", do: row["uid"], else: nil)}

      _row ->
        nil
    end)
  end

  defp missing_channel_context(_state, _frame), do: {:error, :missing_channel_context}

  defp missing_channel_uid(%{"changes" => changes}) when is_list(changes) do
    Enum.find_value(changes, fn
      %{"kind" => "member.status", "uid" => uid} when is_binary(uid) -> uid
      _ -> nil
    end)
  end

  defp missing_channel_uid(_frame), do: nil

  defp channel_repair_target(_state, record, nil), do: {:ok, record.peer_sid}

  defp channel_repair_target(state, _record, uid) when is_binary(uid) do
    case state.runtime.users[uid] do
      %{"home" => %{"sid" => sid}} when is_binary(sid) -> {:ok, sid}
      _ -> {:error, :missing_repair_owner}
    end
  end

  defp channel_repair_key(record, target_sid, channel_name, _mapping),
    do: {target_sid, CaseMapping.normalize(channel_name), record.peer_sid, record.generation}

  defp new_channel_repair(
         key,
         session,
         record,
         target,
         target_sid,
         channel_ref,
         uid,
         frame,
         frame_bytes,
         blocked_merge_id
       ) do
    %{
      key: key,
      session: session,
      peer_sid: record.peer_sid,
      generation: record.generation,
      target_sid: target_sid,
      target_ref: Map.take(target, ["sid", "boot"]),
      channel_ref: channel_ref,
      channel_key: CaseMapping.normalize(channel_ref["name"]),
      uid: uid,
      request_id: nil,
      phase: :begin,
      blocked_merge_id: blocked_merge_id,
      rows: [],
      pending_frames: [frame],
      pending_bytes: frame_bytes,
      expected_rows: nil,
      exists: nil
    }
  end

  defp maybe_start_channel_repair(state, key, repair) do
    cond do
      is_binary(repair.request_id) ->
        {:ok, state}

      is_binary(repair.blocked_merge_id) and MapSet.member?(state.runtime.merge_contexts, repair.blocked_merge_id) ->
        {:ok, state}

      true ->
        case request_target(state, repair.target_sid) do
          {:ok, target} ->
            if target["boot"] == repair.target_ref["boot"] do
              case originate_request(
                     state,
                     target,
                     %{"server" => state.runtime.sid},
                     "snapshot",
                     %{"scope" => "channel", "channel" => repair.channel_ref["name"], "for_uid" => repair.uid},
                     repair_guards(),
                     repair_ttl_ms(state),
                     {:channel_repair, key}
                   ) do
                {:ok, request_id, next} ->
                  next =
                    case next.channel_repairs[key] do
                      nil -> next
                      current -> put_in(next.channel_repairs[key], %{current | request_id: request_id})
                    end

                  {:ok, next}

                {:error, reason} ->
                  {:error, {:channel_repair_start_failed, reason}, state}
              end
            else
              {:error, :repair_owner_generation_changed, state}
            end

          {:error, :target_unreachable} ->
            if current_target_ref?(state, repair) do
              {:ok, state}
            else
              case repair.uid do
                uid when is_binary(uid) -> {:drop, clear_channel_repair(state, key, repair.request_id)}
                _ -> {:error, {:channel_repair_unavailable, :target_unreachable}, state}
              end
            end
        end
    end
  end

  defp current_target_ref?(state, %{target_sid: target_sid, target_ref: %{"boot" => boot}})
       when is_binary(target_sid) and is_binary(boot) do
    match?(%{"sid" => ^target_sid, "boot" => ^boot}, state.runtime.nodes[target_sid])
  end

  defp current_target_ref?(_state, _repair), do: false

  defp release_blocked_channel_repairs(state) do
    Enum.reduce(state.channel_repairs, state, fn {key, repair}, current ->
      case maybe_start_channel_repair(current, key, repair) do
        {:ok, next} -> next
        {:drop, next} -> next
        {:error, reason, next} -> fail_channel_repair(next, key, reason)
      end
    end)
  end

  defp append_channel_repair_frame(state, key, repair, frame, frame_bytes) do
    budgets = section(state.s2s, :budgets)
    max_rows = value(budgets, :max_snapshot_delta_rows, 65_536)
    max_bytes = value(budgets, :snapshot_delta_queue_bytes, 16 * 1_048_576)
    aggregate_bytes = repair_bytes_for_session(state, repair.session)

    cond do
      length(repair.pending_frames) >= max_rows or repair.pending_bytes + frame_bytes > max_bytes ->
        {:error, :channel_repair_queue}

      aggregate_bytes + frame_bytes > max_bytes ->
        {:error, :channel_repair_aggregate_queue}

      true ->
        next =
          put_in(state.channel_repairs[key], %{
            repair
            | pending_frames: [frame | repair.pending_frames],
              pending_bytes: repair.pending_bytes + frame_bytes
          })

        {:ok, next}
    end
  end

  defp repair_capacity_available?(state, session, frame_bytes) do
    budgets = section(state.s2s, :budgets)
    max_repairs = value(budgets, :max_repairs, 16)
    max_bytes = value(budgets, :snapshot_delta_queue_bytes, 16 * 1_048_576)

    cond do
      repair_count(state) >= max_repairs -> {:error, :repair_capacity}
      repair_bytes_for_session(state, session) + frame_bytes > max_bytes -> {:error, :channel_repair_aggregate_queue}
      true -> :ok
    end
  end

  defp repair_bytes_for_session(state, session) do
    channel_bytes =
      state.channel_repairs
      |> Enum.filter(fn {_key, repair} -> repair.session == session end)
      |> Enum.reduce(0, fn {_key, repair}, total -> total + repair.pending_bytes end)

    policy_bytes =
      state.policy_repairs
      |> Enum.filter(fn {_key, repair} -> repair.session == session end)
      |> Enum.reduce(0, fn {_key, repair}, total -> total + repair.pending_bytes end)

    channel_bytes + policy_bytes
  end

  defp repair_guards do
    %{
      "actor_uid" => nil,
      "actor_user_rev" => nil,
      "actor_join_id" => nil,
      "target_user_rev" => nil,
      "target_join_id" => nil,
      "channel" => nil,
      "policy_epoch" => nil,
      "policy_revision" => nil
    }
  end

  defp repair_ttl_ms(state) do
    state.s2s
    |> section(:timeouts)
    |> value(:request_ms, 15_000)
    |> max(1)
    |> min(60_000)
  end

  defp apply_remote_presence(state, _previous_runtime, _effects, true), do: {:ok, state}

  defp apply_remote_presence(state, previous_runtime, effects, false) do
    Enum.each(effects, fn
      %{kind: :user, row: %{"kind" => "user.put", "user" => projection}} ->
        notify_remote_user_change(previous_runtime, state.runtime, projection)

      %{kind: :memberships, row: row, previous: previous, current: current, diff: diff} ->
        materialize_remote_membership_change(previous_runtime, state.runtime, row, previous, current, diff)

      %{kind: :user_quit, row: row, user: projection} when is_map(projection) ->
        notify_remote_offline(previous_runtime, state.runtime, projection, row)
        delete_accept_references(projection["uid"])

      %{kind: :user_quit, row: %{"uid" => uid}} ->
        delete_accept_references(uid)

      _effect ->
        :ok
    end)

    {:ok, state}
  rescue
    _ -> {:ok, state}
  end

  defp notify_remote_user_change(previous_runtime, runtime, projection) do
    uid = projection["uid"]
    previous = previous_runtime.users[uid]

    case {previous, runtime.users[uid]} do
      {nil, %{} = current} ->
        Monitor.notify_online_projection(current, runtime)

      {%{} = old, %{} = current} ->
        old_nick = old["effective_nick"] || old["requested_nick"]
        new_nick = current["effective_nick"] || current["requested_nick"]

        if is_binary(old_nick) and is_binary(new_nick) and
             CaseMapping.normalize(old_nick) != CaseMapping.normalize(new_nick) do
          notify_remote_nick_change(previous_runtime, runtime, old, current)
          Monitor.notify_offline_projection(old, previous_runtime)
          Monitor.notify_online_projection(current, runtime)
        end

        if old["ident"] != current["ident"] or old["displayhost"] != current["displayhost"],
          do: notify_remote_chghost(previous_runtime, runtime, old, current)

        if old["away"] != current["away"],
          do: notify_remote_away(previous_runtime, runtime, old, current)

      _ ->
        :ok
    end
  end

  defp notify_remote_offline(previous_runtime, runtime, projection, row) do
    Monitor.notify_offline_projection(projection, runtime)

    with uid when is_binary(uid) <- projection["uid"],
         %{} = old_memberships <- previous_runtime.memberships[uid],
         {:ok, old_user} <- ServiceEndpoint.caller_user(previous_runtime, uid) do
      Enum.each(old_memberships.entries, fn entry ->
        channel_name = entry["channel"]

        recipients = local_channel_recipients(previous_runtime, channel_name, uid)

        if recipients != [] do
          %Message{command: "QUIT", params: [], trailing: row["reason"] || "connection closed"}
          |> broadcast_remote(%{"by" => %{"user" => uid}}, old_user, previous_runtime, recipients)
        end
      end)
    else
      _ -> :ok
    end
  end

  defp materialize_remote_membership_change(previous_runtime, runtime, row, previous, _current, diff) do
    cause = row["cause"] || %{}
    action = cause["action"]

    if action in ["join", "part", "kick"] do
      uid = row["uid"]
      old_entries = if is_map(previous), do: previous.entries, else: []
      changed_old = changed_entries(old_entries, diff[:changed], runtime.case_mapping)

      case {action, removed_entries(diff, changed_old), added_entries(diff, old_entries, runtime.case_mapping)} do
        {"join", _removed, added} ->
          Enum.each(added, &broadcast_remote_join(runtime, uid, &1))

        {action, removed, _added} when action in ["part", "kick"] ->
          Enum.each(removed, &broadcast_remote_departure(previous_runtime, uid, &1, action, cause))

        _ ->
          :ok
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp removed_entries(diff, changed_old), do: Map.get(diff, :removed, []) ++ changed_old

  defp added_entries(diff, old_entries, mapping) do
    changed_new = Map.get(diff, :changed, [])

    changed_added =
      Enum.filter(changed_new, fn entry ->
        case find_entry(old_entries, entry["channel"], mapping) do
          %{"join_id" => old_join_id} -> old_join_id != entry["join_id"]
          nil -> true
        end
      end)

    Map.get(diff, :added, []) ++ changed_added
  end

  defp changed_entries(old_entries, changed, mapping) do
    Enum.flat_map(changed, fn entry ->
      case find_entry(old_entries, entry["channel"], mapping) do
        %{"join_id" => old_join_id} = old -> if old_join_id != entry["join_id"], do: [old], else: []
        _ -> []
      end
    end)
  end

  defp find_entry(entries, channel_name, _mapping) do
    Enum.find(
      entries,
      &(CaseMapping.normalize(&1["channel"] || "") == CaseMapping.normalize(channel_name || ""))
    )
  end

  defp broadcast_remote_join(runtime, uid, entry) do
    with {:ok, user} <- ServiceEndpoint.caller_user(runtime, uid),
         recipients <- local_channel_recipients(runtime, entry["channel"], uid),
         true <- recipients != [] do
      {extended, ordinary} = Enum.split_with(recipients, &("extended-join" in &1.capabilities))

      if ordinary != [] do
        Dispatcher.broadcast(%Message{command: "JOIN", params: [entry["channel"]]}, user, ordinary)
      end

      if extended != [] do
        Dispatcher.broadcast(
          %Message{
            command: "JOIN",
            params: [entry["channel"], user.identified_as || "*"],
            trailing: user.realname || ""
          },
          user,
          extended
        )
      end
    else
      _ -> :ok
    end
  end

  defp broadcast_remote_departure(runtime, uid, entry, action, cause) do
    with {:ok, user} <- ServiceEndpoint.caller_user(runtime, uid),
         recipients <- local_channel_recipients(runtime, entry["channel"], uid),
         true <- recipients != [] do
      message =
        if action == "kick" do
          %Message{command: "KICK", params: [entry["channel"], user.nick], trailing: cause["reason"] || "remote kick"}
        else
          %Message{command: "PART", params: [entry["channel"]], trailing: cause["reason"] || ""}
        end

      broadcast_remote(message, cause, user, runtime, recipients)
    else
      _ -> :ok
    end
  end

  defp local_channel_recipients(runtime, channel_name, remote_uid) do
    with {:ok, _channel, _runtime_channel} <- View.channel(runtime, channel_name),
         {:ok, recipients} <-
           mnesia_read(fn ->
             with {:ok, local_channel} <- Channels.get_by_name(channel_name) do
               records = UserChannels.get_by_channel_name(local_channel.name)

               actor_membership =
                 if is_binary(remote_uid), do: View.membership(runtime, remote_uid, channel_name), else: :error

               actor_membership = if match?({:ok, _}, actor_membership), do: elem(actor_membership, 1), else: nil

               records
               |> filter_auditorium_users(actor_membership, local_channel.modes)
               |> Enum.map(& &1.user_pid)
               |> Users.get_by_pids()
             end
           end) do
      recipients
    else
      _ -> []
    end
  end

  defp mnesia_read(fun) when is_function(fun, 0) do
    if Memento.Transaction.inside?(), do: {:ok, fun.()}, else: {:ok, Memento.transaction!(fun)}
  catch
    :exit, _reason -> {:error, :mnesia_unavailable}
  end

  defp broadcast_remote(message, %{"by" => %{"user" => actor_uid}}, _fallback, runtime, recipients)
       when is_binary(actor_uid) do
    case ServiceEndpoint.caller_user(runtime, actor_uid) do
      {:ok, actor} -> Dispatcher.broadcast(message, actor, recipients)
      _ -> Dispatcher.broadcast(message, :server, recipients)
    end
  end

  defp broadcast_remote(message, %{"by" => %{"service" => "NickServ"}}, _fallback, _runtime, recipients),
    do: Dispatcher.broadcast(message, :nickserv, recipients)

  defp broadcast_remote(message, %{"by" => %{"service" => "ChanServ"}}, _fallback, _runtime, recipients),
    do: Dispatcher.broadcast(message, :chanserv, recipients)

  defp broadcast_remote(message, %{"by" => %{"server" => sid}}, _fallback, _runtime, recipients)
       when is_binary(sid),
       do: Dispatcher.broadcast(%{message | prefix: sid}, nil, recipients)

  defp broadcast_remote(message, _cause, fallback, _runtime, recipients),
    do: Dispatcher.broadcast(message, fallback, recipients)

  defp notify_remote_nick_change(previous_runtime, runtime, old, current) do
    with {:ok, old_user} <- ServiceEndpoint.caller_user(previous_runtime, old["uid"]),
         new_nick when is_binary(new_nick) <- current["effective_nick"] || current["requested_nick"] do
      channel_names =
        membership_channel_names(previous_runtime, old["uid"]) ++ membership_channel_names(runtime, current["uid"])

      recipients =
        channel_names
        |> Enum.uniq()
        |> Enum.flat_map(&local_channel_recipients(previous_runtime, &1, old["uid"]))
        |> Enum.uniq_by(& &1.pid)

      if recipients != [], do: Dispatcher.broadcast(%Message{command: "NICK", params: [new_nick]}, old_user, recipients)
    else
      _ -> :ok
    end
  end

  defp notify_remote_chghost(previous_runtime, runtime, old, current) do
    if Application.get_env(:elixircd, :capabilities, [])[:chghost] do
      with {:ok, old_user} <- ServiceEndpoint.caller_user(previous_runtime, old["uid"]),
           new_ident when is_binary(new_ident) <- current["ident"],
           new_host when is_binary(new_host) <- current["displayhost"] do
        recipients = shared_remote_recipients(previous_runtime, runtime, old["uid"])
        recipients = Enum.filter(recipients, &("chghost" in &1.capabilities))

        if recipients != [],
          do: Dispatcher.broadcast(%Message{command: "CHGHOST", params: [new_ident, new_host]}, old_user, recipients)
      else
        _ -> :ok
      end
    end
  end

  defp notify_remote_away(previous_runtime, runtime, old, current) do
    with {:ok, old_user} <- ServiceEndpoint.caller_user(previous_runtime, old["uid"]),
         recipients <- shared_remote_recipients(previous_runtime, runtime, old["uid"]),
         true <- recipients != [] do
      text = get_in(current, ["away", "text"])
      Dispatcher.broadcast(%Message{command: "AWAY", params: [], trailing: text}, old_user, recipients)
    else
      _ -> :ok
    end
  end

  defp shared_remote_recipients(previous_runtime, runtime, uid) do
    (membership_channel_names(previous_runtime, uid) ++ membership_channel_names(runtime, uid))
    |> Enum.uniq()
    |> Enum.flat_map(fn channel_name -> local_channel_recipients(previous_runtime, channel_name, uid) end)
    |> Enum.uniq_by(& &1.pid)
  end

  defp membership_channel_names(runtime, uid) do
    case runtime.memberships[uid] do
      %{entries: entries} -> Enum.map(entries, & &1["channel"])
      _ -> []
    end
  end

  defp delete_accept_references(uid) when is_binary(uid) do
    Memento.transaction!(fn -> UserAccepts.delete_by_accepted_user_uid(uid) end)
    :ok
  rescue
    _ -> :ok
  end

  defp delete_accept_references(_uid), do: :ok

  defp queue_state_frame(state, session, record, frame) do
    bytes = frame_budget_bytes(frame)
    budgets = section(state.s2s, :budgets)
    max_bytes = value(budgets, :snapshot_delta_queue_bytes, 16 * 1_048_576)
    max_rows = value(budgets, :max_snapshot_delta_rows, 65_536)
    max_aggregate_rows = value(budgets, :aggregate_pending_frames, 262_144)
    max_aggregate_bytes = value(budgets, :aggregate_pending_bytes, 128 * 1_048_576)
    {aggregate_rows, aggregate_bytes} = pending_sync_queue_totals(state)

    cond do
      length(record.pending_state) >= max_rows or record.pending_state_bytes + bytes > max_bytes ->
        Session.close(session, "RESOURCE", "snapshot delta queue")
        cleanup_session(state, session, :snapshot_delta_queue)

      aggregate_rows >= max_aggregate_rows or aggregate_bytes + bytes > max_aggregate_bytes ->
        Session.close(session, "RESOURCE", "aggregate snapshot delta queue")
        cleanup_session(state, session, :aggregate_snapshot_delta_queue)

      true ->
        next_record = %{
          record
          | pending_state: [frame | record.pending_state],
            pending_state_bytes: record.pending_state_bytes + bytes
        }

        put_session(state, session, next_record)
    end
  end

  defp flush_pending_state(state, session) do
    case state.sessions[session] do
      %{pending_state: pending} = record when pending != [] ->
        initial = put_session(state, session, %{record | pending_state: [], pending_state_bytes: 0})
        replay_state_frames(initial, session, Enum.reverse(pending))

      _ ->
        state
    end
  end

  defp handle_local_reply(state, source_session, frame) do
    case Requests.accept_reply(state.requests, frame) do
      {:ok, requests, result} ->
        if is_function(state.reply_fun, 1), do: state.reply_fun.(result)
        state = %{state | requests: requests}
        deliver_request_waiter(state, frame["request_id"], result)

      {:error, reason} ->
        case handle_message_reply(state, frame) do
          {:handled, next} ->
            next

          {:protocol_error, reason} ->
            if is_pid(source_session) do
              Session.close(source_session, "ORIGIN", safe_reason(reason))
              cleanup_session(state, source_session, reason)
            else
              state
            end

          :not_handled ->
            if is_pid(source_session) and pending_request?(state.requests, frame["request_id"]) do
              Session.close(source_session, "ORIGIN", safe_reason(reason))
              cleanup_session(state, source_session, reason)
            else
              state
            end
        end
    end
  end

  defp handle_message_reply(state, %{"request_id" => request_id} = frame) do
    case state.message_waiters[request_id] do
      %{origin: origin, responder: responder, pid: pid, uid: uid, context: context}
      when is_map(origin) and is_map(responder) and is_pid(pid) and is_binary(uid) and is_map(context) ->
        if frame["to"] == origin and frame["origin"] == responder and frame["part"] == 0 and frame["done"] do
          result = %{
            status: frame["status"],
            payload: frame["payload"],
            part: frame["part"],
            done: frame["done"]
          }

          if Process.alive?(pid), do: send(pid, {:s2s_reply, uid, request_id, result, context})
          {:handled, %{state | message_waiters: Map.delete(state.message_waiters, request_id)}}
        else
          {:protocol_error, :invalid_message_reply_origin}
        end

      _ ->
        :not_handled
    end
  end

  defp handle_message_reply(_state, _frame), do: :not_handled

  defp pending_request?(requests, request_id) when is_binary(request_id) do
    Enum.any?(requests.pending, fn {_key, pending} -> get_in(pending, [:frame, "request_id"]) == request_id end)
  end

  defp pending_request?(_requests, _request_id), do: false

  defp deliver_request_waiter(state, request_id, result) do
    case state.request_waiters[request_id] do
      %{pid: pid, uid: uid, context: context} when is_pid(pid) and is_binary(uid) ->
        if Process.alive?(pid), do: send(pid, {:s2s_reply, uid, request_id, result, context})

        waiters =
          if result[:done] == true,
            do: Map.delete(state.request_waiters, request_id),
            else: state.request_waiters

        %{state | request_waiters: waiters}

      %{pid: pid, uid: uid} when is_pid(pid) and is_binary(uid) ->
        if Process.alive?(pid), do: send(pid, {:s2s_reply, uid, request_id, result, %{}})

        waiters =
          if result[:done] == true,
            do: Map.delete(state.request_waiters, request_id),
            else: state.request_waiters

        %{state | request_waiters: waiters}

      %{kind: :service, job_ref: job_ref} ->
        if result[:done] == true, do: send(self(), {:s2s_service_owner_reply, job_ref, result})

        waiters =
          if result[:done] == true,
            do: Map.delete(state.request_waiters, request_id),
            else: state.request_waiters

        %{state | request_waiters: waiters}

      %{kind: :channel_repair, key: key} ->
        handle_channel_repair_reply(state, key, result)

      %{kind: :policy_repair, key: key} ->
        handle_policy_repair_reply(state, key, result)

      _ ->
        state
    end
  end

  defp notify_expired_waiters(state, expired) do
    Enum.reduce(expired, state, fn request_id, current ->
      case current.request_waiters[request_id] do
        %{pid: pid, uid: uid, context: context} when is_pid(pid) and is_binary(uid) ->
          if Process.alive?(pid) do
            send(pid, {
              :s2s_reply,
              uid,
              request_id,
              %{
                status: "TIMEOUT",
                payload: Requests.error_payload("TIMEOUT", "request expired"),
                part: 0,
                done: true
              },
              context
            })
          end

          %{current | request_waiters: Map.delete(current.request_waiters, request_id)}

        %{pid: pid, uid: uid} when is_pid(pid) and is_binary(uid) ->
          if Process.alive?(pid) do
            send(pid, {
              :s2s_reply,
              uid,
              request_id,
              %{status: "TIMEOUT", payload: Requests.error_payload("TIMEOUT", "request expired"), part: 0, done: true},
              %{}
            })
          end

          %{current | request_waiters: Map.delete(current.request_waiters, request_id)}

        %{kind: :service, job_ref: job_ref} ->
          send(
            self(),
            {:s2s_service_owner_reply, job_ref,
             %{status: "TIMEOUT", payload: Requests.error_payload("TIMEOUT", "request expired"), part: 0, done: true}}
          )

          %{current | request_waiters: Map.delete(current.request_waiters, request_id)}

        %{kind: :channel_repair, key: key} ->
          fail_channel_repair(current, key, :channel_repair_timeout)

        %{kind: :policy_repair, key: key} ->
          fail_policy_repair(current, key, :policy_repair_timeout)

        _ ->
          current
      end
    end)
  end

  defp expire_message_waiters(state, now_ms) do
    {expired, message_waiters} =
      Enum.split_with(state.message_waiters, fn {_request_id, waiter} ->
        is_integer(waiter[:deadline]) and waiter[:deadline] <= now_ms
      end)

    Enum.each(expired, fn {request_id, waiter} ->
      send_message_waiter_reply(
        waiter,
        request_id,
        "TIMEOUT",
        Requests.error_payload("TIMEOUT", "message delivery expired")
      )
    end)

    %{state | message_waiters: Map.new(message_waiters)}
  end

  defp handle_channel_repair_reply(state, key, %{status: "OK", payload: payload, done: done})
       when is_map(payload) and is_boolean(done) do
    part = if Map.has_key?(payload, "result"), do: payload["result"], else: payload

    case state.channel_repairs[key] do
      nil ->
        state

      repair ->
        case channel_repair_part(state, repair, part, done) do
          {:continue, next_repair} -> put_in(state.channel_repairs[key], next_repair)
          {:complete, next_repair} -> complete_channel_repair(state, key, next_repair, part)
          {:error, reason} -> fail_channel_repair(state, key, reason)
        end
    end
  end

  defp handle_channel_repair_reply(state, key, _result),
    do: fail_channel_repair(state, key, :invalid_channel_repair_reply)

  defp channel_repair_part(_state, repair, %{"phase" => "begin", "scope" => "channel", "channel" => channel}, false) do
    if repair.phase == :begin and CaseMapping.normalize(channel) == repair.channel_key,
      do: {:continue, %{repair | phase: :rows}},
      else: {:error, :invalid_channel_repair_begin}
  end

  defp channel_repair_part(state, repair, %{"phase" => "rows", "rows" => rows}, false) when is_list(rows) do
    budgets = section(state.s2s, :budgets)
    max_rows = value(budgets, :max_snapshot_delta_rows, 65_536)
    next_count = length(repair.rows) + length(rows)

    cond do
      repair.phase != :rows -> {:error, :invalid_channel_repair_rows_phase}
      next_count > max_rows -> {:error, :channel_repair_rows_limit}
      not valid_channel_repair_rows?(repair, rows) -> {:error, :invalid_channel_repair_row}
      true -> {:continue, %{repair | rows: repair.rows ++ rows}}
    end
  end

  defp channel_repair_part(
         _state,
         repair,
         %{"phase" => "end", "scope" => "channel", "rows" => count, "exists" => exists},
         true
       )
       when is_integer(count) and count >= 0 and is_boolean(exists) do
    cond do
      repair.phase != :rows -> {:error, :invalid_channel_repair_end}
      count != length(repair.rows) -> {:error, :invalid_channel_repair_end}
      not valid_channel_repair_snapshot?(repair, exists) -> {:error, :invalid_channel_repair_order}
      true -> {:complete, %{repair | expected_rows: count, exists: exists}}
    end
  end

  defp channel_repair_part(_state, _repair, _part, _done), do: {:error, :invalid_channel_repair_phase}

  defp valid_channel_repair_rows?(repair, rows) do
    Enum.all?(rows, &valid_channel_repair_row?(repair, &1))
  end

  defp valid_channel_repair_snapshot?(repair, exists) do
    kinds = Enum.map(repair.rows, & &1["kind"])
    channel_kinds = ["channel.ensure", "channel.field", "channel.list", "member.status"]
    ensure_index = Enum.find_index(kinds, &(&1 == "channel.ensure"))
    first_channel_index = Enum.find_index(kinds, &(&1 in channel_kinds))
    user_index = Enum.find_index(kinds, &(&1 == "user.put"))
    membership_index = Enum.find_index(kinds, &(&1 == "memberships.put"))
    status_index = Enum.find_index(kinds, &(&1 == "member.status"))

    channel_order? =
      exists and is_integer(ensure_index) and
        (is_nil(first_channel_index) or ensure_index == first_channel_index)

    absent_channel? = not exists and Enum.all?(kinds, &(&1 not in channel_kinds))

    owner_order? =
      (is_nil(user_index) or is_nil(membership_index) or user_index < membership_index) and
        (is_nil(membership_index) or is_nil(status_index) or membership_index < status_index)

    (channel_order? or absent_channel?) and owner_order?
  end

  defp valid_channel_repair_row?(repair, %{"kind" => kind, "channel" => channel})
       when kind in ["channel.ensure", "channel.field", "channel.list", "member.status"] do
    same_channel_ref?(channel, repair.channel_ref)
  end

  defp valid_channel_repair_row?(repair, %{"kind" => "user.put", "user" => %{"uid" => uid, "home" => home}})
       when is_binary(repair.uid),
       do: uid == repair.uid and same_node_ref?(home, repair.target_ref)

  defp valid_channel_repair_row?(repair, %{"kind" => "memberships.put", "uid" => uid, "home" => home})
       when is_binary(repair.uid),
       do: uid == repair.uid and same_node_ref?(home, repair.target_ref)

  defp valid_channel_repair_row?(_repair, _row), do: false

  defp same_node_ref?(%{"sid" => sid, "boot" => boot}, %{"sid" => sid, "boot" => boot}), do: true
  defp same_node_ref?(_left, _right), do: false

  defp same_channel_ref?(
         %{"name" => name, "born_ms" => born_ms, "cid" => cid},
         %{"name" => expected_name, "born_ms" => expected_born_ms, "cid" => expected_cid}
       ) do
    CaseMapping.normalize(name) == CaseMapping.normalize(expected_name) and
      born_ms == expected_born_ms and cid == expected_cid
  end

  defp same_channel_ref?(_left, _right), do: false

  defp complete_channel_repair(state, key, repair, part) do
    case Runtime.apply_snapshot_rows(
           state.runtime,
           repair.rows,
           repair.target_ref,
           %{"kind" => "live"},
           source_sid: repair.target_sid,
           snapshot: true
         ) do
      {:ok, runtime, effects} ->
        :ok = Output.observe_stamps(stamps_from_rows(repair.rows))

        with {:ok, next} <- apply_runtime_effects(%{state | runtime: runtime}, effects, suppress_c2s: true),
             {:ok, next} <- apply_remote_presence(next, state.runtime, effects, true),
             :ok <- channel_repair_dependency(next.runtime, repair, part["exists"]) do
          next = publish_repair_rows(next, repair, effects)
          next = clear_channel_repair(next, key, repair.request_id)

          if part["exists"],
            do: replay_channel_repair_frames(next, repair),
            else:
              replay_channel_repair_frames(%{next | channel_repairs: Map.delete(next.channel_repairs, key)}, %{
                repair
                | pending_frames: []
              })
        else
          {:error, reason} -> fail_channel_repair(state, key, reason)
        end

      {:error, reason} ->
        if reason in [:stale_channel_incarnation, :channel_not_ensured],
          do: clear_channel_repair(state, key, repair.request_id),
          else: fail_channel_repair(state, key, {:channel_repair_apply_failed, reason})
    end
  end

  defp channel_repair_dependency(runtime, repair, true) do
    if Map.has_key?(runtime.channels, repair.channel_key), do: :ok, else: {:error, :channel_repair_channel_missing}
  end

  defp channel_repair_dependency(runtime, repair, false) do
    live_membership? =
      is_binary(repair.uid) and
        match?(%{entries: entries} when is_list(entries), runtime.memberships[repair.uid]) and
        Enum.any?(runtime.memberships[repair.uid].entries, fn entry ->
          CaseMapping.normalize(entry["channel"] || "") == repair.channel_key
        end)

    if live_membership?, do: {:error, :channel_repair_membership_still_live}, else: :ok
  end

  defp publish_repair_rows(state, repair, effects) do
    rows =
      effects
      |> Enum.flat_map(fn
        %{row: row} when is_map(row) -> [row]
        _effect -> []
      end)
      |> Enum.uniq()

    if rows == [],
      do: state,
      else: publish_merge_rows(state, repair.session, rows, %{"kind" => "live"}, repair.target_ref)
  end

  defp clear_channel_repair(state, key, request_id) do
    request_waiters =
      if is_binary(request_id), do: Map.delete(state.request_waiters, request_id), else: state.request_waiters

    requests = if is_binary(request_id), do: Requests.cancel(state.requests, request_id), else: state.requests

    %{
      state
      | channel_repairs: Map.delete(state.channel_repairs, key),
        request_waiters: request_waiters,
        requests: requests
    }
  end

  defp fail_channel_repair(state, key, reason) do
    case state.channel_repairs[key] do
      nil ->
        state

      repair ->
        request_waiters =
          if is_binary(repair.request_id),
            do: Map.delete(state.request_waiters, repair.request_id),
            else: state.request_waiters

        requests =
          if is_binary(repair.request_id), do: Requests.cancel(state.requests, repair.request_id), else: state.requests

        next = %{
          state
          | channel_repairs: Map.delete(state.channel_repairs, key),
            request_waiters: request_waiters,
            requests: requests
        }

        case next.sessions[repair.session] do
          %{generation: generation} when generation == repair.generation ->
            Session.close(repair.session, "DEPENDENCY", safe_reason(reason))
            cleanup_session(next, repair.session, reason)

          _ ->
            next
        end
    end
  end

  defp replay_channel_repair_frames(state, repair) do
    before = repair_keys_for_session(state, repair.session)
    next = replay_state_frames(state, repair.session, Enum.reverse(repair.pending_frames))

    if repair_keys_for_session(next, repair.session) == before,
      do: flush_pending_state(next, repair.session),
      else: next
  end

  defp repair_keys_for_session(state, session) do
    state.channel_repairs
    |> Enum.filter(fn {_key, repair} -> repair.session == session end)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp replay_state_frames(state, session, frames) when is_list(frames) do
    Enum.reduce_while(Enum.with_index(frames), state, fn {frame, index}, current ->
      case current.sessions[session] do
        %{generation: generation} = record ->
          case apply_state_frame(current, session, record, frame) do
            {:ok, next} ->
              {:cont, next}

            {:deferred, next} ->
              rest = Enum.drop(frames, index + 1)
              {:halt, retain_pending_state(next, session, rest, generation)}

            {:error, reason, next} ->
              Session.close(session, "ORIGIN", safe_reason(reason))
              {:halt, cleanup_session(next, session, reason)}
          end

        _ ->
          {:halt, current}
      end
    end)
  end

  defp retain_pending_state(state, _session, [], _generation), do: state

  defp retain_pending_state(state, session, frames, generation) do
    case state.sessions[session] do
      %{generation: ^generation} = record ->
        bytes = Enum.reduce(frames, 0, fn frame, total -> total + frame_budget_bytes(frame) end)
        budgets = section(state.s2s, :budgets)
        max_rows = value(budgets, :max_snapshot_delta_rows, 65_536)
        max_bytes = value(budgets, :snapshot_delta_queue_bytes, 16 * 1_048_576)
        max_aggregate_rows = value(budgets, :aggregate_pending_frames, 262_144)
        max_aggregate_bytes = value(budgets, :aggregate_pending_bytes, 128 * 1_048_576)
        {aggregate_rows, aggregate_bytes} = pending_sync_queue_totals(state)

        cond do
          length(record.pending_state) + length(frames) > max_rows or
              record.pending_state_bytes + bytes > max_bytes ->
            Session.close(session, "RESOURCE", "snapshot delta queue")
            cleanup_session(state, session, :snapshot_delta_queue)

          aggregate_rows + length(frames) > max_aggregate_rows or
              aggregate_bytes + bytes > max_aggregate_bytes ->
            Session.close(session, "RESOURCE", "aggregate snapshot delta queue")
            cleanup_session(state, session, :aggregate_snapshot_delta_queue)

          true ->
            put_session(state, session, %{
              record
              | pending_state: Enum.reverse(frames) ++ record.pending_state,
                pending_state_bytes: record.pending_state_bytes + bytes
            })
        end

      _ ->
        state
    end
  end

  defp handle_policy_repair_reply(state, key, %{status: "OK", payload: payload, done: done})
       when is_map(payload) and is_boolean(done) do
    part = if Map.has_key?(payload, "result"), do: payload["result"], else: payload

    case state.policy_repairs[key] do
      nil ->
        state

      repair ->
        case policy_repair_part(state, repair, part, done) do
          {:continue, next_repair} -> put_in(state.policy_repairs[key], next_repair)
          {:complete, next_repair} -> complete_policy_repair(state, key, next_repair)
          {:error, reason} -> fail_policy_repair(state, key, reason)
        end
    end
  end

  defp handle_policy_repair_reply(state, key, _result),
    do: fail_policy_repair(state, key, :invalid_policy_repair_reply)

  defp policy_repair_part(
         state,
         repair,
         %{"snapshot" => "policy", "phase" => "begin", "epoch" => epoch, "revision" => revision, "objects" => objects},
         false
       ) do
    cond do
      repair.phase != :begin ->
        {:error, :invalid_policy_repair_begin}

      epoch != state.runtime.policy.epoch ->
        {:error, :policy_repair_epoch_mismatch}

      not is_integer(objects) or objects < 0 ->
        {:error, :invalid_policy_repair_object_count}

      true ->
        {:continue, %{repair | phase: :rows, begin: true, epoch: epoch, revision: revision, expected_objects: objects}}
    end
  end

  defp policy_repair_part(state, repair, %{"snapshot" => "policy", "phase" => "rows", "rows" => objects}, false)
       when is_list(objects) do
    max_objects = value(section(state.s2s, :budgets), :max_policy_objects, 65_536)
    next_count = length(repair.objects) + length(objects)

    cond do
      repair.phase != :rows -> {:error, :invalid_policy_repair_rows_phase}
      next_count > max_objects -> {:error, :policy_repair_object_limit}
      not Enum.all?(objects, &policy_repair_object_valid?/1) -> {:error, :invalid_policy_repair_object}
      true -> {:continue, %{repair | objects: repair.objects ++ objects}}
    end
  end

  defp policy_repair_part(
         _state,
         repair,
         %{"snapshot" => "policy", "phase" => "end", "epoch" => epoch, "revision" => revision, "objects" => objects},
         true
       ) do
    if repair.phase == :rows and repair.epoch == epoch and repair.revision == revision and
         repair.expected_objects == objects and length(repair.objects) == objects,
       do: {:complete, repair},
       else: {:error, :invalid_policy_repair_end}
  end

  defp policy_repair_part(_state, _repair, _part, _done), do: {:error, :invalid_policy_repair_phase}

  defp policy_repair_object_valid?(%{"entity" => entity, "key" => key, "value" => value}),
    do: ElixIRCd.Server.S2S.Policy.validate_public_object(entity, key, value) == :ok

  defp policy_repair_object_valid?(_object), do: false

  defp complete_policy_repair(state, key, repair) do
    cache_rows =
      [
        %{
          "kind" => "policy.cache.begin",
          "epoch" => repair.epoch,
          "revision" => repair.revision,
          "objects" => repair.expected_objects
        }
      ] ++
        (repair.objects
         |> Enum.chunk_every(256)
         |> Enum.map(&%{"kind" => "policy.cache.rows", "rows" => &1})) ++
        [
          %{
            "kind" => "policy.cache.end",
            "epoch" => repair.epoch,
            "revision" => repair.revision,
            "objects" => repair.expected_objects
          }
        ]

    case Runtime.apply_snapshot_rows(
           state.runtime,
           cache_rows,
           repair.target_ref,
           %{"kind" => "live"},
           source_sid: repair.target_sid,
           snapshot: true
         ) do
      {:ok, runtime, effects} ->
        with {:ok, next} <- apply_runtime_effects(%{state | runtime: runtime}, effects, suppress_c2s: true),
             {:ok, next} <- apply_remote_presence(next, state.runtime, effects, true) do
          next = clear_policy_repair(next, key, repair.request_id)
          before = policy_repair_keys_for_session(next, repair.session)
          next = replay_state_frames(next, repair.session, Enum.reverse(repair.pending_frames))

          if policy_repair_keys_for_session(next, repair.session) == before,
            do: flush_pending_state(next, repair.session),
            else: next
        else
          {:error, reason} -> fail_policy_repair(state, key, reason)
        end

      {:error, reason} ->
        fail_policy_repair(state, key, {:policy_repair_apply_failed, reason})
    end
  end

  defp clear_policy_repair(state, key, request_id) do
    request_waiters =
      if is_binary(request_id), do: Map.delete(state.request_waiters, request_id), else: state.request_waiters

    requests = if is_binary(request_id), do: Requests.cancel(state.requests, request_id), else: state.requests

    %{
      state
      | policy_repairs: Map.delete(state.policy_repairs, key),
        request_waiters: request_waiters,
        requests: requests
    }
  end

  defp fail_policy_repair(state, key, reason) do
    case state.policy_repairs[key] do
      nil ->
        state

      repair ->
        request_waiters =
          if is_binary(repair.request_id),
            do: Map.delete(state.request_waiters, repair.request_id),
            else: state.request_waiters

        requests =
          if is_binary(repair.request_id), do: Requests.cancel(state.requests, repair.request_id), else: state.requests

        next = %{
          state
          | policy_repairs: Map.delete(state.policy_repairs, key),
            request_waiters: request_waiters,
            requests: requests
        }

        case next.sessions[repair.session] do
          %{generation: generation} when generation == repair.generation ->
            Session.close(repair.session, "DEPENDENCY", safe_reason(reason))
            cleanup_session(next, repair.session, reason)

          _ ->
            next
        end
    end
  end

  defp policy_repair_keys_for_session(state, session) do
    state.policy_repairs
    |> Enum.filter(fn {_key, repair} -> repair.session == session end)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp execute_admitted_request(state, session, record, frame, requests, now) do
    context = request_context(state, record, frame) |> Map.put(:request_session, session)

    case request_actor_allowed?(state, frame) do
      false ->
        {status, payload, executed_state} =
          {"REJECTED", Requests.failure_payload(frame, "REJECTED", "actor is not owned by the request origin"), state}

        finish_admitted_request(executed_state, session, frame, requests, status, payload, now)

      true ->
        admitted_state = %{state | requests: requests}

        case execute_request(admitted_state, frame, context) do
          {:async, executed_state} when is_map(executed_state) ->
            {:noreply, executed_state}

          {:async, job_fun} when is_function(job_fun, 0) ->
            start_service_job(
              admitted_state,
              session,
              frame,
              {:inside_transaction, job_fun},
              now
            )

          {:async_deferred, job_fun} when is_function(job_fun, 0) ->
            start_service_job(
              admitted_state,
              session,
              frame,
              {:outside_transaction, job_fun},
              now
            )

          {status, payload, executed_state} ->
            finish_admitted_request(executed_state, session, frame, executed_state.requests, status, payload, now)
        end
    end
  end

  @spec finish_admitted_request(
          map(),
          pid() | nil,
          map(),
          Requests.state(),
          String.t(),
          map() | {:stream, list()},
          integer()
        ) :: {:noreply, map()}
  defp finish_admitted_request(state, session, frame, requests, status, {:stream, parts} = payload, now)
       when is_list(parts) do
    if stream_within_budget?(state, parts) do
      if is_nil(session) do
        {:noreply, send_stream_replies(%{state | requests: requests}, session, frame, status, parts)}
      else
        with {:ok, completed} <-
               Requests.complete(requests, frame["request_id"], %{status: status, payload: payload}, now) do
          {:noreply, send_stream_replies(%{state | requests: completed}, session, frame, status, parts)}
        else
          {:error, _reason} -> {:noreply, state}
        end
      end
    else
      finish_admitted_request(
        state,
        session,
        frame,
        requests,
        "RESOURCE",
        Requests.failure_payload(frame, "RESOURCE", "response stream exceeds the configured budget"),
        now
      )
    end
  end

  defp finish_admitted_request(state, session, frame, requests, status, payload, now) do
    with {:ok, requests, reply} <- Requests.reply(requests, frame["request_id"], 0, true, status, payload, 1),
         true <- is_map(reply) do
      if is_nil(session) do
        {:noreply, route_frame(%{state | requests: requests}, nil, reply)}
      else
        with {:ok, completed} <-
               Requests.complete(requests, frame["request_id"], %{status: status, payload: payload}, now) do
          {:noreply, route_frame(%{state | requests: completed}, session, reply)}
        else
          {:error, _reason} -> {:noreply, state}
        end
      end
    else
      {:error, _reason} -> {:noreply, state}
    end
  end

  defp start_service_job(state, session, frame, job_spec, _now) do
    if map_size(state.service_jobs) >= state.service_workers do
      finish_admitted_request(
        state,
        session,
        frame,
        state.requests,
        "BUSY",
        Requests.failure_payload(frame, "BUSY", "service execution capacity is exhausted"),
        Requests.monotonic_ms()
      )
    else
      job_ref = Identity.nonce()
      manager = self()

      {pid, monitor_ref} =
        spawn_monitor(fn ->
          result =
            try do
              deferred_service_job(job_spec)
            rescue
              _ -> {:reply, "REJECTED", Requests.error_payload("REJECTED", "service execution failed")}
            catch
              _kind, _reason -> {:reply, "REJECTED", Requests.error_payload("REJECTED", "service execution failed")}
            end

          send(manager, {:s2s_service_job_done, job_ref, result})
        end)

      job = %{
        job_ref: job_ref,
        session: session,
        frame: frame,
        pid: pid,
        monitor_ref: monitor_ref,
        stage: :authority,
        success_payload: nil
      }

      {:noreply, %{state | service_jobs: Map.put(state.service_jobs, job_ref, job)}}
    end
  end

  defp deferred_service_job({:inside_transaction, job_fun}) when is_function(job_fun, 0) do
    deferred_service_transaction(fn -> job_fun.() end)
  end

  defp deferred_service_job({:outside_transaction, job_fun}) when is_function(job_fun, 0) do
    case job_fun.() do
      {:deferred_transaction, commit_fun} when is_function(commit_fun, 0) ->
        deferred_service_transaction(commit_fun)

      result ->
        result
    end
  end

  defp deferred_service_transaction(transaction_fun) when is_function(transaction_fun, 0) do
    case Output.transaction_deferred(fn ->
           Publication.with_policy_refresh_suppressed(fn -> defer_service_result(transaction_fun.()) end)
         end) do
      {:ok, result, nil} -> result
      {:ok, result, group} -> {:deferred_output, result, group}
      {:error, reason} -> {:error, "UNKNOWN_OUTCOME", safe_reason(reason)}
    end
  end

  defp defer_service_result({:state_rows, payload, rows}) when is_list(rows) do
    with :ok <- collect_service_rows(rows) do
      {:state_rows, payload, []}
    end
  end

  defp defer_service_result({:owner_action, action}) when is_map(action) do
    with :ok <- collect_service_rows(action[:pre_rows] || []) do
      {:owner_action, Map.put(action, :pre_rows, [])}
    end
  end

  defp defer_service_result(result), do: result

  defp collect_service_rows([]), do: :ok

  defp collect_service_rows(rows) when is_list(rows) do
    valid? = Enum.all?(rows, &(Schema.validate_row(&1) == :ok))

    if valid? do
      case Output.collect_intent(%{kind: :s2s_rows, rows: rows}) do
        :ok -> :ok
        {:error, reason} -> Memento.Transaction.abort({:service_output_rejected, reason})
        :inactive -> Memento.Transaction.abort(:service_output_inactive)
      end
    else
      Memento.Transaction.abort(:invalid_service_output_rows)
    end
  end

  defp collect_service_rows(_rows), do: Memento.Transaction.abort(:invalid_service_output_rows)

  defp drain_service_group(state, group) when is_map(group) do
    key = {__MODULE__, :deferred_service_output, make_ref()}
    Process.put(key, state)

    result =
      try do
        Output.drain_pending(group, &drain_service_output_intent(key, &1))
      rescue
        error -> {:error, {:drain_failed, Exception.message(error)}}
      catch
        kind, reason -> {:error, {:drain_failed, {kind, reason}}}
      end

    next = Process.get(key, state)
    Process.delete(key)

    case result do
      :ok -> {:ok, next}
      {:error, reason} -> {:error, reason, next}
    end
  end

  defp drain_service_output_intent(key, %{kind: :s2s_rows, rows: rows}) do
    case publish_domain_rows(Process.get(key), rows) do
      {:ok, next} ->
        Process.put(key, next)
        :ok

      {:error, reason, next} ->
        Process.put(key, next)
        {:error, reason}
    end
  end

  defp drain_service_output_intent(_key, intent), do: Dispatcher.drain_intent(intent)

  defp execute_service_callback(state, frame, context) do
    key = {__MODULE__, :service_output, make_ref()}
    Process.put(key, state)

    result =
      try do
        Output.transaction(
          fn ->
            Publication.with_policy_refresh_suppressed(fn ->
              case execute_callback(state.service_fun, frame, state.runtime, context) do
                {:ok, payload, rows} when is_list(rows) ->
                  with :ok <- collect_service_rows(rows) do
                    {:ok, payload}
                  end

                other ->
                  other
              end
            end)
          end,
          drain_fun: &drain_service_output_intent(key, &1)
        )
      rescue
        _ -> {:error, :callback_exception}
      catch
        _kind, _reason -> {:error, :callback_exception}
      end

    next = Process.get(key, state)
    Process.delete(key)

    case result do
      {:ok, payload} -> {:ok, payload, next}
      {:ok, status, payload} when is_binary(status) -> {:ok, status, payload, next}
      {:async, job_fun} when is_function(job_fun, 0) -> {:async, job_fun}
      {:async_deferred, job_fun} when is_function(job_fun, 0) -> {:async_deferred, job_fun}
      :unsupported -> :unsupported
      {:error, status, message} -> {:error, status, message, next}
      {:error, _reason} -> {:error, "UNKNOWN_OUTCOME", "service publication was incomplete", next}
      _ -> {:error, "REJECTED", "invalid service result", next}
    end
  end

  defp finish_service_job(state, job_ref, job, {:owner_action, action}) when is_map(action) do
    case publish_service_rows(state, action[:pre_rows] || []) do
      {:ok, prepared} ->
        action = put_current_policy_guards(action, prepared.runtime)

        with target_sid when is_binary(target_sid) <- action[:target_sid],
             {:ok, target} <- request_target(prepared, target_sid),
             {:ok, owner_request_id, next} <-
               originate_request(
                 prepared,
                 target,
                 action[:actor],
                 action[:method],
                 action[:args],
                 action[:guards],
                 action[:ttl_ms],
                 {:service, job_ref}
               ) do
          job =
            Map.merge(job, %{
              stage: :owner,
              owner_request_id: owner_request_id,
              success_payload: action[:success_payload],
              follow_up: action[:follow_up],
              remaining_actions: action[:remaining_actions] || [],
              committed_count: 0
            })

          {:noreply, %{next | service_jobs: Map.put(next.service_jobs, job_ref, job)}}
        else
          _ ->
            finish_service_request(
              prepared,
              job,
              "UNAVAILABLE",
              Requests.error_payload("UNAVAILABLE", "service owner is unavailable")
            )
        end

      {:error, _reason, failed} ->
        finish_service_request(
          failed,
          job,
          "UNKNOWN_OUTCOME",
          Requests.error_payload("UNKNOWN_OUTCOME", "service authority publication was incomplete")
        )
    end
  end

  defp finish_service_job(state, job_ref, job, {:deferred_output, result, group})
       when is_map(group) do
    case drain_service_group(state, group) do
      {:ok, next} ->
        finish_service_job(next, job_ref, job, result)

      {:error, _reason, failed} ->
        finish_service_request(
          failed,
          job,
          "UNKNOWN_OUTCOME",
          Requests.error_payload("UNKNOWN_OUTCOME", "service publication was incomplete")
        )
    end
  end

  defp finish_service_job(state, _job_ref, job, {:state_rows, payload, rows}) when is_list(rows) do
    case publish_service_rows(state, rows) do
      {:ok, next} ->
        finish_service_request(next, job, "OK", payload)

      {:error, _reason, failed} ->
        finish_service_request(
          failed,
          job,
          "UNKNOWN_OUTCOME",
          Requests.error_payload("UNKNOWN_OUTCOME", "service publication was incomplete")
        )
    end
  end

  defp finish_service_job(state, _job_ref, job, {:follow_up, payload, follow_up})
       when is_map(payload) and is_map(follow_up),
       do: finish_service_follow_up(state, job, payload, follow_up, false)

  defp finish_service_job(state, _job_ref, job, {:reply, status, payload})
       when is_binary(status) and is_map(payload),
       do: finish_service_request(state, job, status, payload)

  defp finish_service_job(state, _job_ref, job, {:error, status, message})
       when is_binary(status) and is_binary(message),
       do: finish_service_request(state, job, status, Requests.error_payload(status, message))

  defp finish_service_job(state, _job_ref, job, _result),
    do: finish_service_request(state, job, "REJECTED", Requests.error_payload("REJECTED", "invalid service result"))

  defp finish_service_owner_reply(state, job, %{status: status, payload: payload})
       when is_binary(status) and is_map(payload) do
    if status == "OK" do
      case job[:remaining_actions] || [] do
        [next_action | remaining] ->
          start_next_service_owner_action(state, job, next_action, remaining)

        [] ->
          case job[:follow_up] do
            follow_up when is_map(follow_up) ->
              finish_service_follow_up(state, job, job.success_payload || Requests.ok_payload(nil), follow_up, true)

            _ ->
              finish_service_request(state, job, "OK", job.success_payload || Requests.ok_payload(nil))
          end
      end
    else
      if (job[:committed_count] || 0) > 0 do
        finish_service_request(
          state,
          job,
          "UNKNOWN_OUTCOME",
          Requests.error_payload("UNKNOWN_OUTCOME", "one or more service owner actions committed before failure")
        )
      else
        finish_service_request(state, job, status, payload)
      end
    end
  end

  defp finish_service_owner_reply(state, job, _result),
    do: finish_service_request(state, job, "REJECTED", Requests.error_payload("REJECTED", "invalid owner result"))

  defp start_next_service_owner_action(state, job, action, remaining) when is_map(action) do
    case publish_service_rows(state, action[:pre_rows] || []) do
      {:ok, prepared} ->
        action = put_current_policy_guards(action, prepared.runtime)

        with target_sid when is_binary(target_sid) <- action[:target_sid],
             {:ok, target} <- request_target(prepared, target_sid),
             {:ok, owner_request_id, next} <-
               originate_request(
                 prepared,
                 target,
                 action[:actor],
                 action[:method],
                 action[:args],
                 action[:guards],
                 action[:ttl_ms],
                 {:service, job.job_ref}
               ) do
          next_job =
            Map.merge(job, %{
              stage: :owner,
              owner_request_id: owner_request_id,
              remaining_actions: remaining,
              committed_count: (job[:committed_count] || 0) + 1
            })

          {:noreply, %{next | service_jobs: Map.put(next.service_jobs, job.job_ref, next_job)}}
        else
          _ ->
            finish_service_request(
              prepared,
              job,
              "UNKNOWN_OUTCOME",
              Requests.error_payload("UNKNOWN_OUTCOME", "a committed service action could not reach its next owner")
            )
        end

      {:error, _reason, failed} ->
        finish_service_request(
          failed,
          job,
          "UNKNOWN_OUTCOME",
          Requests.error_payload("UNKNOWN_OUTCOME", "service authority publication was incomplete")
        )
    end
  end

  defp finish_service_request(state, job, status, payload) do
    finish_admitted_request(
      state,
      job.session,
      job.frame,
      state.requests,
      status,
      payload,
      Requests.monotonic_ms()
    )
  end

  defp finish_service_follow_up(state, job, payload, follow_up, owner_committed?) do
    case apply_service_follow_up(state, follow_up) do
      {:ok, next} ->
        finish_service_request(next, job, "OK", payload)

      {:error, status, message, next} when is_binary(status) and is_binary(message) and not owner_committed? ->
        finish_service_request(next, job, status, Requests.error_payload(status, message))

      {:error, _reason, next} ->
        finish_service_request(
          next,
          job,
          "UNKNOWN_OUTCOME",
          Requests.error_payload("UNKNOWN_OUTCOME", "service owner action committed but follow-up was incomplete")
        )
    end
  end

  defp apply_service_follow_up(state, follow_up) when is_map(follow_up) do
    key = {__MODULE__, :service_follow_up, make_ref()}
    Process.put(key, state)

    result =
      try do
        Output.transaction(
          fn ->
            Publication.with_policy_refresh_suppressed(fn ->
              case ServiceEndpoint.apply_follow_up(follow_up, state.runtime) do
                {:ok, rows} ->
                  with :ok <- collect_service_rows(rows) do
                    :ok
                  end

                {:error, _status, _message} = error ->
                  error
              end
            end)
          end,
          drain_fun: &drain_service_output_intent(key, &1)
        )
      rescue
        _ -> {:error, :publication_failed}
      catch
        _kind, _reason -> {:error, :publication_failed}
      end

    next = Process.get(key, state)
    Process.delete(key)

    case result do
      :ok -> {:ok, next}
      {:error, status, message} -> {:error, status, message, next}
      {:error, _reason} -> {:error, :publication_failed, next}
      _ -> {:error, :invalid_follow_up_result, next}
    end
  end

  defp publish_service_rows(state, []), do: {:ok, state}

  defp publish_service_rows(state, rows) when is_list(rows), do: publish_domain_rows(state, rows)

  defp publish_service_rows(state, _rows), do: {:error, :invalid_service_rows, state}

  defp put_current_policy_guards(%{guards: guards} = action, runtime) when is_map(guards) do
    %{
      action
      | guards:
          Map.merge(guards, %{"policy_epoch" => runtime.policy.epoch, "policy_revision" => runtime.policy.revision})
    }
  end

  defp put_current_policy_guards(action, _runtime), do: action

  defp send_stream_replies(state, session, request, status, parts) do
    parts = if parts == [], do: [%{"phase" => "end", "scope" => "channel", "rows" => 0, "exists" => false}], else: parts

    if stream_within_budget?(state, parts) do
      last_index = length(parts) - 1

      Enum.reduce(Enum.with_index(parts), state, fn {part, index}, current ->
        done = index == last_index
        payload = stream_part_payload(request, part)

        case Requests.build_reply_from_request(request, status, payload, index, done, 1) do
          {:ok, reply} -> route_frame(current, session, reply)
          {:error, _} -> current
        end
      end)
    else
      send_stream_resource_reply(state, session, request)
    end
  end

  defp stream_part_payload(request, part) do
    cond do
      request["method"] == "snapshot" -> part
      request["method"] in ["service", "query"] and is_map(part) and Map.has_key?(part, "items") -> part
      true -> Requests.ok_payload(part)
    end
  end

  defp send_stream_resource_reply(state, session, request) do
    payload = Requests.failure_payload(request, "RESOURCE", "response stream exceeds the configured budget")

    case Requests.build_reply_from_request(request, "RESOURCE", payload, 0, true, 1) do
      {:ok, reply} -> route_frame(state, session, reply)
      {:error, _} -> state
    end
  end

  defp stream_within_budget?(state, parts) when is_list(parts) do
    budgets = section(state.s2s, :budgets)
    max_parts = value(budgets, :max_stream_parts, 4_096)
    max_bytes = value(budgets, :max_stream_bytes, value(budgets, :per_link_queue_bytes, 16 * 1_048_576))

    length(parts) <= max_parts and
      Enum.reduce_while(parts, 0, fn part, bytes ->
        next = bytes + frame_budget_bytes(part)
        if next <= max_bytes, do: {:cont, next}, else: {:halt, max_bytes + 1}
      end) <= max_bytes
  end

  defp stream_within_budget?(_state, _parts), do: false

  defp request_target(state, target_sid) when is_binary(target_sid) do
    case state.runtime.nodes[target_sid] do
      %{"sid" => ^target_sid, "boot" => boot} = node ->
        if MapSet.member?(state.runtime.reachable_sids, target_sid),
          do: {:ok, %{"sid" => target_sid, "boot" => boot, "name" => node["name"]}},
          else: {:error, :target_unreachable}

      _ ->
        {:error, :target_unreachable}
    end
  end

  defp request_target(_state, _target_sid), do: {:error, :target_unreachable}

  defp originate_request(state, target, actor, method, args, guards, ttl_ms, waiter) do
    request_id = Identity.nonce()

    with {:ok, frame} <-
           Requests.build(
             %{"sid" => state.runtime.sid, "boot" => state.runtime.boot},
             Map.take(target, ["sid", "boot"]),
             request_id,
             actor,
             method,
             args,
             guards,
             ttl_ms,
             1
           ),
         {:ok, requests, _pending} <- Requests.admit(state.requests, frame),
         next <-
           %{state | requests: requests}
           |> put_request_waiter(request_id, waiter)
           |> originate_or_execute(target, frame, requests) do
      {:ok, request_id, next}
    end
  end

  defp put_message_waiter(
         state,
         %{"command" => "PRIVMSG", "target" => %{"user" => target_uid}, "request_id" => request_id} = frame,
         options
       )
       when is_binary(request_id) do
    with {pid, uid, context} <- Keyword.get(options, :reply_to),
         true <- is_pid(pid) and is_binary(uid) and is_map(context),
         %{"home" => responder} <- state.runtime.users[target_uid],
         true <- is_map(responder) do
      waiter = %{
        origin: frame["origin"],
        responder: responder,
        pid: pid,
        uid: uid,
        context: context,
        deadline: Requests.monotonic_ms() + @message_delivery_ttl_ms
      }

      %{state | message_waiters: Map.put(state.message_waiters, request_id, waiter)}
    else
      _ -> state
    end
  end

  defp put_message_waiter(state, _frame, _options), do: state

  defp put_request_waiter(state, _request_id, nil), do: state

  defp put_request_waiter(state, request_id, {pid, uid, context})
       when is_pid(pid) and is_binary(uid) and is_map(context) do
    %{state | request_waiters: Map.put(state.request_waiters, request_id, %{pid: pid, uid: uid, context: context})}
  end

  defp put_request_waiter(state, request_id, {pid, uid}) when is_pid(pid) and is_binary(uid) do
    %{state | request_waiters: Map.put(state.request_waiters, request_id, %{pid: pid, uid: uid, context: %{}})}
  end

  defp put_request_waiter(state, request_id, {:service, job_ref}) when is_binary(job_ref) do
    %{state | request_waiters: Map.put(state.request_waiters, request_id, %{kind: :service, job_ref: job_ref})}
  end

  defp put_request_waiter(state, request_id, {:channel_repair, key}) when is_binary(request_id) do
    %{state | request_waiters: Map.put(state.request_waiters, request_id, %{kind: :channel_repair, key: key})}
  end

  defp put_request_waiter(state, request_id, {:policy_repair, key}) when is_binary(request_id) do
    %{state | request_waiters: Map.put(state.request_waiters, request_id, %{kind: :policy_repair, key: key})}
  end

  defp put_request_waiter(state, _request_id, _waiter), do: state

  defp cancel_recipient_requests(state, recipient, uid) do
    request_ids =
      (Map.to_list(state.request_waiters) ++ Map.to_list(state.message_waiters))
      |> Enum.filter(fn {_request_id, waiter} -> waiter[:pid] == recipient and waiter[:uid] == uid end)
      |> Enum.map(&elem(&1, 0))

    cancel_request_ids(state, request_ids, "request cancelled by connection teardown")
  end

  defp cancel_origin_sasl_requests(state, recipient, uid, attempt_id) do
    request_ids =
      state.requests.pending
      |> Enum.filter(fn {_key, %{frame: frame}} ->
        frame["origin"]["sid"] == state.runtime.sid and
          frame["method"] == "sasl" and
          get_in(frame, ["args", "uid"]) == uid and
          get_in(frame, ["args", "attempt_id"]) == attempt_id and
          request_waiter_matches?(state.request_waiters, frame["request_id"], recipient, uid)
      end)
      |> Enum.map(fn {_key, %{frame: frame}} -> frame["request_id"] end)

    cancel_sasl_request_ids(state, request_ids)
  end

  defp request_waiter_matches?(waiters, request_id, recipient, uid) do
    case waiters[request_id] do
      %{pid: ^recipient, uid: ^uid} -> true
      _ -> false
    end
  end

  defp cancel_sasl_request_ids(state, request_ids) do
    request_ids = request_ids |> Enum.filter(&is_binary/1) |> MapSet.new()

    if MapSet.size(request_ids) == 0 do
      state
    else
      requests = Enum.reduce(request_ids, state.requests, &Requests.cancel(&2, &1))
      request_waiters = Enum.reduce(request_ids, state.request_waiters, &Map.delete(&2, &1))
      sasl_jobs = cancel_sasl_request_jobs(state.sasl_jobs, request_ids, state.sasl_pool)

      %{state | requests: requests, request_waiters: request_waiters, sasl_jobs: sasl_jobs}
    end
  end

  defp cancel_link_requests(state, peer_sid) do
    request_ids =
      state.requests.pending
      |> Enum.flat_map(fn {_key, %{frame: frame}} ->
        if request_route_uses_peer?(state, frame, peer_sid), do: [frame["request_id"]], else: []
      end)

    message_ids =
      state.message_waiters
      |> Enum.filter(fn {_request_id, waiter} -> message_route_uses_peer?(state, waiter, peer_sid) end)
      |> Enum.map(&elem(&1, 0))

    uncertain_request_ids =
      state.requests.pending
      |> Enum.flat_map(fn {_key, %{frame: frame}} ->
        request_id = frame["request_id"]

        if request_id in request_ids and uncertain_route_request?(frame), do: [request_id], else: []
      end)

    state
    |> cancel_request_ids(uncertain_request_ids, "request route is unavailable", "UNKNOWN_OUTCOME")
    |> cancel_request_ids((request_ids -- uncertain_request_ids) ++ message_ids, "request route is unavailable")
  end

  defp uncertain_route_request?(%{"method" => "service", "args" => args}) when is_map(args),
    do: uncertain_service_request?(args)

  defp uncertain_route_request?(%{"method" => method}) when method in ~w(user_action invite admin), do: true

  defp uncertain_route_request?(_frame), do: false

  @read_only_service_commands %{
    "NickServ" => ~w(ALIST HELP INFO LIST LISTCHANS STATUS),
    "ChanServ" => ~w(ALIST HELP INFO STATUS)
  }

  defp uncertain_service_request?(%{"service" => service, "arguments" => [verb | _]})
       when is_binary(service) and is_binary(verb) do
    String.upcase(verb) not in Map.get(@read_only_service_commands, service, [])
  end

  defp uncertain_service_request?(_args), do: true

  defp message_route_uses_peer?(state, %{responder: %{"sid" => target_sid}}, peer_sid) do
    Tree.next_hop(state.roster, state.runtime.sid, target_sid) == {:ok, peer_sid}
  end

  defp message_route_uses_peer?(_state, _waiter, _peer_sid), do: false

  defp request_route_uses_peer?(state, %{"origin" => %{"sid" => origin_sid}, "to" => %{"sid" => target_sid}}, peer_sid) do
    local_sid = state.runtime.sid

    destination =
      cond do
        origin_sid == local_sid and target_sid != local_sid -> target_sid
        target_sid == local_sid and origin_sid != local_sid -> origin_sid
        true -> nil
      end

    destination != nil and Tree.next_hop(state.roster, local_sid, destination) == {:ok, peer_sid}
  end

  defp request_route_uses_peer?(_state, _frame, _peer_sid), do: false

  defp cancel_request_ids(state, request_ids, reason, terminal_status \\ "CANCELLED") do
    request_ids = request_ids |> Enum.filter(&is_binary/1) |> MapSet.new()

    expanded_ids =
      Enum.reduce(state.service_jobs, request_ids, fn {_job_ref, job}, ids ->
        outer_id = get_in(job, [:frame, "request_id"])
        owner_id = job[:owner_request_id]

        if MapSet.member?(ids, outer_id) or MapSet.member?(ids, owner_id),
          do: ids |> put_binary_id(outer_id) |> put_binary_id(owner_id),
          else: ids
      end)

    requests = Enum.reduce(expanded_ids, state.requests, &Requests.cancel(&2, &1))

    channel_repairs =
      Enum.reduce(state.channel_repairs, state.channel_repairs, fn {key, repair}, repairs ->
        if MapSet.member?(expanded_ids, repair.request_id), do: Map.delete(repairs, key), else: repairs
      end)

    policy_repairs =
      Enum.reduce(state.policy_repairs, state.policy_repairs, fn {key, repair}, repairs ->
        if MapSet.member?(expanded_ids, repair.request_id), do: Map.delete(repairs, key), else: repairs
      end)

    request_waiters =
      Enum.reduce(expanded_ids, state.request_waiters, fn request_id, waiters ->
        case Map.pop(waiters, request_id) do
          {nil, waiters} ->
            waiters

          {%{pid: pid, uid: uid, context: context}, waiters}
          when is_pid(pid) and is_binary(uid) and is_map(context) ->
            send_cancelled_reply(pid, uid, request_id, context, reason, terminal_status)
            waiters

          {%{pid: pid, uid: uid}, waiters} when is_pid(pid) and is_binary(uid) ->
            send_cancelled_reply(pid, uid, request_id, %{}, reason, terminal_status)
            waiters

          {_waiter, waiters} ->
            waiters
        end
      end)

    message_waiters =
      Enum.reduce(expanded_ids, state.message_waiters, fn request_id, waiters ->
        case Map.pop(waiters, request_id) do
          {nil, waiters} ->
            waiters

          {waiter, waiters} ->
            send_message_waiter_reply(
              waiter,
              request_id,
              "CANCELLED",
              Requests.error_payload("CANCELLED", reason)
            )

            waiters
        end
      end)

    service_jobs =
      Enum.reduce(state.service_jobs, %{}, fn {job_ref, job}, jobs ->
        outer_id = get_in(job, [:frame, "request_id"])
        owner_id = job[:owner_request_id]

        if MapSet.member?(expanded_ids, outer_id) or MapSet.member?(expanded_ids, owner_id) do
          if job[:stage] == :authority and is_pid(job[:pid]), do: Process.exit(job[:pid], :kill)
          if is_reference(job[:monitor_ref]), do: Process.demonitor(job[:monitor_ref], [:flush])
          jobs
        else
          Map.put(jobs, job_ref, job)
        end
      end)

    sasl_jobs = cancel_sasl_request_jobs(state.sasl_jobs, expanded_ids, state.sasl_pool)

    %{
      state
      | requests: requests,
        request_waiters: request_waiters,
        message_waiters: message_waiters,
        channel_repairs: channel_repairs,
        policy_repairs: policy_repairs,
        service_jobs: service_jobs,
        sasl_jobs: sasl_jobs
    }
  end

  defp put_binary_id(ids, id) when is_binary(id), do: MapSet.put(ids, id)
  defp put_binary_id(ids, _id), do: ids

  defp send_cancelled_reply(pid, uid, request_id, context, reason, status) do
    if Process.alive?(pid) do
      send(pid, {
        :s2s_reply,
        uid,
        request_id,
        %{status: status, payload: Requests.error_payload(status, reason), part: 0, done: true},
        context
      })
    end
  end

  defp send_message_waiter_reply(
         %{pid: pid, uid: uid, context: context},
         request_id,
         status,
         payload
       )
       when is_pid(pid) and is_binary(uid) and is_binary(request_id) and is_map(context) and is_binary(status) and
              is_map(payload) do
    if Process.alive?(pid) do
      send(pid, {
        :s2s_reply,
        uid,
        request_id,
        %{status: status, payload: payload, part: 0, done: true},
        context
      })
    end

    :ok
  end

  defp send_message_waiter_reply(_waiter, _request_id, _status, _payload), do: :ok

  defp originate_or_execute(state, %{"sid" => sid}, frame, requests) when sid == state.runtime.sid do
    {:noreply, next} = execute_admitted_request(state, nil, nil, frame, requests, Requests.monotonic_ms())
    next
  end

  defp originate_or_execute(state, _target, frame, _requests), do: route_frame(state, nil, frame)

  defp request_context(state, _record, frame) do
    remote_admin = section(state.s2s, :remote_admin)
    actor = frame["actor"]
    actor_user = if is_map(actor), do: state.runtime.users[actor["user"]], else: nil
    target_home_sid = target_home_sid(state.runtime, frame)
    operator_role = operator_role(actor_user, frame["origin"]["sid"])

    %{
      local_sid: state.runtime.sid,
      services_authority: state.runtime.services_authority,
      policy_ready: ElixIRCd.Server.S2S.Policy.grant_ready?(state.runtime.policy),
      auth_available: sasl_available?(state.sasl_options),
      target_home_sid: target_home_sid,
      origin_sid: frame["origin"]["sid"],
      origin_boot: frame["origin"]["boot"],
      direct_neighbors: Tree.neighbors(state.roster, state.runtime.sid),
      remote_admin_enabled: value(remote_admin, :enabled, false),
      remote_admin_actions: value(remote_admin, :actions, []),
      remote_admin_origins: value(remote_admin, :origin_sids, value(remote_admin, :origins, [])),
      remote_admin_roles: value(remote_admin, :operator_roles, value(remote_admin, :roles, [])),
      operator_role: operator_role,
      owner_detail: owner_detail_allowed?(state.runtime, actor, frame),
      defer_expensive?: true
    }
  end

  defp request_actor_allowed?(state, %{"origin" => origin, "actor" => actor}) do
    case actor do
      %{"server" => sid} ->
        sid == origin["sid"] and node_ref_current?(state, sid, origin["boot"])

      %{"service" => service} when service in ~w(NickServ ChanServ) ->
        origin["sid"] == state.runtime.services_authority and
          node_ref_current?(state, origin["sid"], origin["boot"])

      %{"user" => uid} ->
        case state.runtime.users[uid] do
          %{"home" => home} -> home == origin
          _ -> false
        end

      _ ->
        false
    end
  end

  defp request_actor_allowed?(_state, _frame), do: false

  defp target_home_sid(runtime, %{"args" => %{"target_uid" => uid}}) when is_binary(uid),
    do: get_in(runtime.users, [uid, "home", "sid"])

  defp target_home_sid(_runtime, frame), do: get_in(frame, ["to", "sid"])

  defp operator_role(%{"home" => %{"sid" => sid}, "oper_role" => role}, sid) when is_binary(role), do: role
  defp operator_role(_user, _origin_sid), do: nil

  defp owner_detail_allowed?(runtime, %{"user" => actor_uid}, %{"args" => %{"target_uid" => target_uid}}),
    do: actor_uid == target_uid or get_in(runtime.users, [actor_uid, "oper_role"]) != nil

  defp owner_detail_allowed?(_runtime, _actor, _frame), do: false

  defp capture_dynamic_capabilities(runtime) do
    users = Memento.transaction!(fn -> Users.get_all() end)
    Map.new(users, fn user -> {user.pid, Cap.capability_map(user, runtime)} end)
  rescue
    _ -> nil
  end

  defp maybe_notify_dynamic_capabilities(state, previous_runtime, old_capability_maps)
       when is_map(old_capability_maps) do
    _ = Monitor.notify_service_presence_change(previous_runtime, state.runtime)

    if dynamic_capability_context_changed?(previous_runtime, state.runtime) do
      _ = Cap.notify_dynamic_changes(old_capability_maps, state.runtime)
    end

    state
  end

  defp maybe_notify_dynamic_capabilities(state, previous_runtime, _old_capability_maps) do
    _ = Monitor.notify_service_presence_change(previous_runtime, state.runtime)
    state
  end

  defp dynamic_capability_context_changed?(previous_runtime, runtime) do
    previous_runtime.services_authority != runtime.services_authority or
      previous_runtime.reachable_sids != runtime.reachable_sids
  end

  defp sasl_available?(options) when is_list(options),
    do:
      is_function(Keyword.get(options, :plain_lookup), 3) or
        is_function(Keyword.get(options, :ecdsa_lookup), 2) or
        is_function(Keyword.get(options, :ecdsa_lookup), 3)

  defp sasl_available?(_options), do: false

  defp execute_request(state, frame, context) do
    case Requests.authorize(frame, context) do
      :ok ->
        execute_authorized_request(state, frame, context)

      {:error, status} ->
        {status, Requests.failure_payload(frame, status, "request is not available"), state}
    end
  end

  defp execute_authorized_request(state, %{"method" => "sasl"} = frame, context),
    do: execute_sasl(state, frame, context)

  defp execute_authorized_request(state, %{"method" => "admin"} = frame, context),
    do: execute_admin(state, frame, context)

  defp execute_authorized_request(state, %{"method" => "query"} = frame, context) do
    case execute_callback(state.query_fun, frame, state.runtime, context) do
      :unsupported ->
        {"UNSUPPORTED", Requests.failure_payload(frame, "UNSUPPORTED", "query execution is not configured"), state}

      {:ok, {:stream, parts}} ->
        {"OK", {:stream, parts}, state}

      {:ok, payload, rows} when is_list(rows) ->
        apply_service_publication(state, frame, payload, rows)

      {:ok, status, payload} when is_binary(status) ->
        {status, payload, state}

      {:ok, payload} ->
        {"OK", payload, state}

      {:async, job_fun} when is_function(job_fun, 0) ->
        {:async, job_fun}

      {:async_deferred, job_fun} when is_function(job_fun, 0) ->
        {:async_deferred, job_fun}

      {:error, status, message} ->
        {status, Requests.failure_payload(frame, status, message), state}
    end
  end

  defp execute_authorized_request(state, %{"method" => "snapshot"} = frame, context) do
    case execute_callback(state.snapshot_fun, frame, state.runtime, context) do
      :unsupported -> execute_snapshot(state, frame)
      {:ok, payload} -> {"OK", payload, state}
      {:ok, status, payload} -> {status, payload, state}
      {:error, status, message} -> {status, Requests.failure_payload(frame, status, message), state}
    end
  end

  defp execute_authorized_request(state, %{"method" => "service"} = frame, context) do
    case execute_service_callback(state, frame, context) do
      :unsupported ->
        {"UNSUPPORTED", Requests.failure_payload(frame, "UNSUPPORTED", "request execution is not configured"), state}

      {:ok, payload, next} ->
        {"OK", payload, next}

      {:ok, status, payload, next} when is_binary(status) ->
        {status, payload, next}

      {:async, job_fun} when is_function(job_fun, 0) ->
        {:async, job_fun}

      {:async_deferred, job_fun} when is_function(job_fun, 0) ->
        {:async_deferred, job_fun}

      {:error, status, message, next} ->
        {status, Requests.failure_payload(frame, status, message), next}
    end
  end

  defp execute_authorized_request(state, %{"method" => method} = frame, context)
       when method in ["user_action", "invite"] do
    callback =
      case method do
        "user_action" -> state.action_fun
        "invite" -> state.action_fun
      end

    case execute_callback(callback, frame, state.runtime, context) do
      :unsupported when method in ["user_action", "invite"] ->
        execute_builtin_domain(state, frame, context)

      :unsupported ->
        {"UNSUPPORTED", Requests.failure_payload(frame, "UNSUPPORTED", "request execution is not configured"), state}

      {:ok, payload, rows} when is_list(rows) ->
        apply_service_publication(state, frame, payload, rows)

      {:ok, status, payload} when is_binary(status) ->
        {status, payload, state}

      {:ok, payload} ->
        {"OK", payload, state}

      {:async, job_fun} when is_function(job_fun, 0) ->
        {:async, job_fun}

      {:error, status, message} ->
        {status, Requests.failure_payload(frame, status, message), state}
    end
  end

  defp execute_authorized_request(state, frame, context) do
    {status, payload} = execute_request_fun(state.request_fun, frame, state.runtime, context)
    {status, payload, state}
  end

  defp execute_builtin_domain(state, frame, context) do
    case Domain.execute_deferred(frame, state.runtime, context) do
      {:ok, result, group} ->
        case drain_deferred_domain_group(state, group) do
          {:ok, next} ->
            {"OK", Requests.ok_payload(result), next}

          {:error, _reason, next} ->
            {"UNKNOWN_OUTCOME",
             Requests.failure_payload(frame, "UNKNOWN_OUTCOME", "owner committed but publication was incomplete"), next}
        end

      {:error, status, message, group} ->
        case drain_deferred_domain_group(state, group) do
          {:ok, next} ->
            {status, Requests.failure_payload(frame, status, message), next}

          {:error, _reason, next} ->
            {"UNKNOWN_OUTCOME",
             Requests.failure_payload(frame, "UNKNOWN_OUTCOME", "owner outcome could not be published"), next}
        end
    end
  end

  defp drain_deferred_domain_group(state, nil), do: {:ok, state}

  defp drain_deferred_domain_group(state, group) when is_map(group) do
    key = {__MODULE__, :deferred_domain_output, make_ref()}

    Process.put(key, %{state: state, remaining: length(group.intents), c2s: []})

    result =
      try do
        Output.drain_pending(group, &drain_deferred_domain_intent(key, &1))
      rescue
        error -> {:error, {:domain_output_drain_failed, Exception.message(error)}}
      catch
        kind, reason -> {:error, {:domain_output_drain_failed, {kind, reason}}}
      end

    context = Process.get(key, %{state: state})
    Process.delete(key)

    case result do
      :ok -> {:ok, context.state}
      {:error, reason} -> {:error, reason, context.state}
    end
  end

  defp drain_deferred_domain_group(state, _group), do: {:error, :invalid_domain_output_group, state}

  defp drain_deferred_domain_intent(key, intent) when is_map(intent) do
    context = Process.get(key)

    if is_map(context) do
      case apply_deferred_domain_intent(context.state, intent) do
        {:ok, next, :defer_c2s} ->
          finish_deferred_domain_intent(key, %{context | state: next, c2s: [intent | context.c2s]})

        {:ok, next, :applied} ->
          finish_deferred_domain_intent(key, %{context | state: next})

        {:error, reason, next} ->
          Process.put(key, %{context | state: next})
          {:error, reason}
      end
    else
      {:error, :missing_domain_output_context}
    end
  end

  defp drain_deferred_domain_intent(_key, _intent), do: {:error, :invalid_domain_output_intent}

  defp finish_deferred_domain_intent(key, %{remaining: remaining} = context) when remaining > 1 do
    Process.put(key, %{context | remaining: remaining - 1})
    :ok
  end

  defp finish_deferred_domain_intent(key, %{remaining: 1, c2s: c2s} = context) do
    case Output.drain_effects(Enum.reverse(c2s), &Dispatcher.drain_intent/1) do
      :ok ->
        Process.put(key, %{context | remaining: 0})
        :ok

      {:error, reason} ->
        Process.put(key, %{context | remaining: 0})
        {:error, {:c2s_output_failed, reason}}
    end
  end

  defp finish_deferred_domain_intent(_key, _context), do: {:error, :invalid_domain_output_sequence}

  defp apply_deferred_domain_intent(state, %{kind: :s2s_rows, rows: rows}) do
    case publish_domain_rows(state, rows) do
      {:ok, next} -> {:ok, next, :applied}
      {:error, reason, next} -> {:error, reason, next}
    end
  end

  defp apply_deferred_domain_intent(state, %{kind: kind} = intent)
       when kind in [:s2s_user_put, :s2s_user_quit, :s2s_memberships, :s2s_channel, :s2s_channel_list] do
    case Publication.rows_for_intent(intent, state.local_hello,
           policy_epoch: state.runtime.policy.epoch,
           policy: state.runtime.policy
         ) do
      {:ok, rows} ->
        case publish_domain_rows(state, rows) do
          {:ok, next} -> {:ok, next, :applied}
          {:error, reason, next} -> {:error, reason, next}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp apply_deferred_domain_intent(state, %{kind: kind})
       when kind in [:c2s_message, :c2s_disconnect, :connection_cleanup] do
    {:ok, state, :defer_c2s}
  end

  defp apply_deferred_domain_intent(state, _intent), do: {:error, :invalid_domain_effect, state}

  defp apply_runtime_effects(state, effects, options \\ []) when is_list(effects) do
    Enum.reduce_while(effects, {:ok, state}, fn
      %{removed_channels: names}, {:ok, current} when is_list(names) ->
        Enum.each(names, &LocalChannel.prune(current.runtime, &1))
        {:cont, {:ok, current}}

      %{kind: :channel_removed, name: name}, {:ok, current} when is_binary(name) ->
        _ = LocalChannel.prune(current.runtime, name)
        {:cont, {:ok, current}}

      %{kind: :channel, row: %{"channel" => %{"name" => name}}}, {:ok, current}
      when is_binary(name) ->
        _ = LocalChannel.reconcile(current.runtime, name)
        {:cont, {:ok, current}}

      %{kind: :invite, row: row, origin: origin}, {:ok, current} when is_map(row) and is_map(origin) ->
        if Keyword.get(options, :suppress_c2s, false) or origin == local_origin(current) do
          {:cont, {:ok, current}}
        else
          case materialize_invite_notice(current, row) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end

      %{kind: :status, row: row}, {:ok, current} when is_map(row) ->
        if Keyword.get(options, :suppress_c2s, false) do
          {:cont, {:ok, current}}
        else
          if local_status_owner?(current.runtime, row) do
            case materialize_status_effect(current, row) do
              {:ok, next} -> {:cont, {:ok, next}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          else
            {:cont, {:ok, current}}
          end
        end

      %{kind: :binding_invalidated, uid: uid, home: home}, {:ok, current}
      when is_binary(uid) and is_map(home) ->
        if home == %{"sid" => current.runtime.sid, "boot" => current.runtime.boot} do
          case clear_local_binding(current, uid) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:cont, {:ok, current}}
        end

      %{kind: :binding_mode, uid: uid, home: home, enabled: enabled}, {:ok, current}
      when is_binary(uid) and is_map(home) and is_boolean(enabled) ->
        if home == %{"sid" => current.runtime.sid, "boot" => current.runtime.boot} do
          case materialize_binding_mode(current, uid, enabled) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:cont, {:ok, current}}
        end

      _effect, {:ok, current} ->
        {:cont, {:ok, current}}

      _effect, {:error, _reason} = error ->
        {:halt, error}
    end)
  end

  defp local_status_owner?(runtime, %{"uid" => uid}) when is_binary(uid) do
    case runtime.users[uid] do
      %{"home" => %{"sid" => sid, "boot" => boot}} -> sid == runtime.sid and boot == runtime.boot
      _ -> false
    end
  end

  defp local_status_owner?(_runtime, _row), do: false

  defp materialize_invite_notice(state, %{
         "target_uid" => target_uid,
         "channel" => %{"name" => channel_name}
       })
       when is_binary(target_uid) and is_binary(channel_name) do
    target_nick =
      case state.runtime.users[target_uid] do
        %{"effective_nick" => nick} when is_binary(nick) -> nick
        %{"requested_nick" => nick} when is_binary(nick) -> nick
        _ -> nil
      end

    if is_binary(target_nick) do
      result =
        Output.transaction(
          fn ->
            observers =
              channel_name
              |> UserChannels.get_by_channel_name()
              |> Enum.map(& &1.uid)
              |> Users.get_by_uids()
              |> Enum.filter(&("invite-notify" in &1.capabilities))

            %Message{command: "INVITE", params: [target_nick, channel_name]}
            |> Dispatcher.broadcast(:server, observers)

            :ok
          end,
          persist: false,
          drain_fun: &Dispatcher.drain_intent/1
        )

      case result do
        :ok -> {:ok, state}
        {:error, reason} -> {:error, {:invite_notice_failed, reason}}
      end
    else
      {:error, :invite_target_projection_missing}
    end
  end

  defp materialize_invite_notice(_state, _row), do: {:error, :invalid_invite_notice_effect}

  defp materialize_status_effect(state, row) do
    Process.put(@status_materialization_key, [])

    result =
      Output.transaction(
        fn ->
          with {:ok, user} <- Users.get_by_uid(row["uid"]),
               true <- user.home_sid == state.runtime.sid and user.home_boot == state.runtime.boot,
               {:ok, mode} <- ModeRegistry.decode(:membership, row["mode"]),
               {:ok, membership} <- local_membership(row["uid"], row["channel"]["name"], row["join_id"]),
               {:ok, updated} <- update_local_status(membership, mode, row["enabled"]),
               recipients <- local_channel_users(row["channel"]["name"]),
               :ok <-
                 broadcast_status(
                   row["channel"]["name"],
                   user.nick || "*",
                   mode,
                   row["enabled"],
                   recipients
                 ) do
            {:changed, updated}
          else
            :unchanged -> :unchanged
            {:error, _reason} = error -> error
            false -> {:error, :local_status_owner_mismatch}
          end
        end,
        drain_fun: fn intent ->
          current = Process.get(@status_materialization_key, [])
          Process.put(@status_materialization_key, [intent | current])
          :ok
        end
      )

    intents = Process.get(@status_materialization_key, []) |> Enum.reverse()
    Process.delete(@status_materialization_key)

    c2s_effects = Enum.filter(intents, &(&1[:kind] == :c2s_message))

    case Output.drain_effects(c2s_effects, &Dispatcher.drain_intent/1) do
      :ok ->
        case result do
          {:changed, _updated} -> {:ok, state}
          :unchanged -> {:ok, state}
          {:error, reason} -> {:error, {:status_materialization_failed, reason}}
          other -> {:error, {:status_materialization_result, inspect(other)}}
        end

      {:error, reason} ->
        {:error, {:status_output_failed, reason}}
    end
  rescue
    error ->
      Process.delete(@status_materialization_key)
      {:error, {:status_materialization_exception, Exception.message(error)}}
  end

  defp local_membership(uid, channel_name, join_id) do
    case Enum.find(UserChannels.get_by_uid(uid), fn membership ->
           membership.channel_name_key == CaseMapping.normalize(channel_name) and membership.join_id == join_id
         end) do
      %{} = membership -> {:ok, membership}
      nil -> {:error, :local_membership_missing}
    end
  end

  defp update_local_status(membership, mode, enabled) when is_boolean(enabled) do
    modes = if enabled, do: Enum.uniq([mode | membership.modes]), else: List.delete(membership.modes, mode)

    if modes == membership.modes do
      :unchanged
    else
      {:ok, UserChannels.update(membership, %{modes: modes})}
    end
  end

  defp update_local_status(_membership, _mode, _enabled), do: {:error, :invalid_status_value}

  defp local_channel_users(channel_name) do
    channel_name
    |> UserChannels.get_by_channel_name()
    |> Enum.map(& &1.uid)
    |> Users.get_by_uids()
  end

  defp broadcast_status(channel_name, nick, mode, enabled, recipients) do
    mode = ModeRegistry.encode!(:membership, mode)
    prefix = if enabled, do: "+", else: "-"

    %Message{command: "MODE", params: [channel_name, prefix <> mode, nick]}
    |> Dispatcher.broadcast(:chanserv, recipients)
  end

  defp clear_local_binding(state, uid) do
    key = @binding_invalidation_key
    Process.put(key, [])

    result =
      Output.transaction(
        fn ->
          case Users.get_by_uid(uid) do
            {:ok, user}
            when user.home_sid == state.runtime.sid and user.home_boot == state.runtime.boot and
                   is_binary(user.identified_as) ->
              account_name = user.identified_as

              updated =
                Users.update(user, %{
                  identified_as: nil,
                  sasl_authenticated: false,
                  sasl_attempts: 0,
                  modes: List.delete(user.modes, :r)
                })

              %Message{command: "MODE", params: [updated.nick || "*", "-r"]}
              |> Dispatcher.broadcast(:server, updated)

              %Message{
                command: :rpl_loggedout,
                params: [updated.nick || "*", user_mask(updated, :registration)],
                trailing: "You are no longer identified (was: #{account_name})"
              }
              |> Dispatcher.broadcast(:server, updated)

              Nickserv.notify_account_logout(updated)
              {:updated, updated}

            _ ->
              :unchanged
          end
        end,
        drain_fun: fn intent ->
          Process.put(key, [intent | Process.get(key, [])])
          :ok
        end
      )

    intents = Process.get(key, []) |> Enum.reverse()
    Process.delete(key)

    case result do
      {:updated, _user} -> apply_domain_effects(state, intents)
      :unchanged -> {:ok, state}
      _ -> {:error, :binding_invalidation_failed}
    end
  rescue
    _ ->
      Process.delete(@binding_invalidation_key)
      {:error, :binding_invalidation_failed}
  end

  defp materialize_binding_mode(state, uid, enabled) do
    key = @binding_mode_key
    Process.put(key, [])

    result =
      Output.transaction(
        fn ->
          case Users.get_by_uid(uid) do
            {:ok, user}
            when user.home_sid == state.runtime.sid and user.home_boot == state.runtime.boot and
                   is_binary(user.identified_as) ->
              modes = if enabled, do: Enum.uniq([:r | user.modes]), else: List.delete(user.modes, :r)

              if modes == user.modes do
                :unchanged
              else
                updated = Users.update(user, %{modes: modes})
                command = if enabled, do: "+r", else: "-r"

                Dispatcher.broadcast(
                  %Message{command: "MODE", params: [updated.nick || "*", command]},
                  :server,
                  updated
                )

                Publication.user_changed(updated)
                {:updated, updated}
              end

            _ ->
              :unchanged
          end
        end,
        drain_fun: fn intent ->
          Process.put(key, [intent | Process.get(key, [])])
          :ok
        end
      )

    intents = Process.get(key, []) |> Enum.reverse()
    Process.delete(key)

    case result do
      {:updated, _user} -> apply_domain_effects(state, intents)
      :unchanged -> {:ok, state}
      _ -> {:error, :binding_mode_materialization_failed}
    end
  rescue
    _ ->
      Process.delete(@binding_mode_key)
      {:error, :binding_mode_materialization_failed}
  end

  defp apply_domain_effects(state, effects) when is_list(effects) do
    c2s_effects = Enum.filter(effects, &(&1[:kind] in [:c2s_message, :c2s_disconnect, :connection_cleanup]))

    result =
      Enum.reduce_while(effects, {:ok, state}, fn
        %{kind: :s2s_rows, rows: rows}, {:ok, current} ->
          case publish_domain_rows(current, rows) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, reason, next} -> {:halt, {:error, reason, next}}
          end

        %{kind: kind} = intent, {:ok, current}
        when kind in [:s2s_user_put, :s2s_user_quit, :s2s_memberships, :s2s_channel, :s2s_channel_list] ->
          case Publication.rows_for_intent(intent, current.local_hello,
                 policy_epoch: current.runtime.policy.epoch,
                 policy: current.runtime.policy
               ) do
            {:ok, rows} ->
              case publish_domain_rows(current, rows) do
                {:ok, next} -> {:cont, {:ok, next}}
                {:error, reason, next} -> {:halt, {:error, reason, next}}
              end

            {:error, reason} ->
              {:halt, {:error, reason, current}}
          end

        %{kind: kind}, {:ok, current} when kind in [:c2s_message, :c2s_disconnect, :connection_cleanup] ->
          {:cont, {:ok, current}}

        _intent, {:ok, current} ->
          {:halt, {:error, :invalid_domain_effect, current}}

        _intent, {:error, _reason, _current} = error ->
          {:halt, error}
      end)

    case result do
      {:ok, next} ->
        case Output.drain_effects(c2s_effects, &Dispatcher.drain_intent/1) do
          :ok -> {:ok, next}
          {:error, reason} -> {:error, {:c2s_output_failed, reason}, next}
        end

      {:error, _reason, _next} = error ->
        error
    end
  end

  defp publish_domain_rows(state, rows) when is_list(rows) do
    Enum.reduce_while(Enum.chunk_every(rows, 256), {:ok, state}, fn chunk, {:ok, current} ->
      case publish_local_rows(current, chunk) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason, current}}
      end
    end)
    |> case do
      {:ok, next} -> {:ok, next}
      {:error, reason, next} -> {:error, reason, next}
    end
  end

  defp publish_domain_rows(state, _rows), do: {:error, :invalid_domain_rows, state}

  defp execute_callback(fun, frame, runtime, context) when is_function(fun, 3) do
    normalize_callback_result(fun.(frame, runtime, context))
  rescue
    _ -> {:error, "REJECTED", "request execution failed"}
  end

  defp execute_callback(_fun, _frame, _runtime, _context), do: :unsupported

  defp apply_service_publication(state, frame, payload, rows) do
    case publish_domain_rows(state, rows) do
      {:ok, next} ->
        {"OK", payload, next}

      {:error, _reason, next} ->
        {"UNKNOWN_OUTCOME",
         Requests.failure_payload(frame, "UNKNOWN_OUTCOME", "service committed but policy publication was incomplete"),
         next}
    end
  end

  defp execute_snapshot(state, %{"args" => %{"scope" => "policy"}} = _frame) do
    if state.runtime.services_authority == state.runtime.sid and
         ElixIRCd.Server.S2S.Policy.grant_ready?(state.runtime.policy) do
      objects =
        state.runtime.policy.objects
        |> Enum.sort_by(fn {{entity, key}, _value} -> {entity, key} end)
        |> Enum.map(fn {{entity, key}, value} -> %{"entity" => entity, "key" => key, "value" => value} end)

      parts =
        [
          %{
            "snapshot" => "policy",
            "phase" => "begin",
            "epoch" => state.runtime.policy.epoch,
            "revision" => state.runtime.policy.revision,
            "objects" => length(objects)
          }
        ] ++
          Enum.map(Enum.chunk_every(objects, 256), &%{"snapshot" => "policy", "phase" => "rows", "rows" => &1}) ++
          [
            %{
              "snapshot" => "policy",
              "phase" => "end",
              "epoch" => state.runtime.policy.epoch,
              "revision" => state.runtime.policy.revision,
              "objects" => length(objects)
            }
          ]

      {"OK", {:stream, parts}, state}
    else
      {"UNAVAILABLE",
       Requests.failure_payload(%{"method" => "snapshot"}, "UNAVAILABLE", "policy authority is unavailable"), state}
    end
  end

  defp execute_snapshot(
         state,
         %{"args" => %{"scope" => "channel", "channel" => channel_name, "for_uid" => uid}} = _frame
       ) do
    projections = Runtime.export_projections(state.runtime)
    channel_key = CaseMapping.normalize(channel_name)

    channel_rows =
      projections.channels
      |> Enum.filter(fn row -> CaseMapping.normalize(get_in(row, ["channel", "name"]) || "") == channel_key end)

    status_rows =
      projections.status
      |> Enum.filter(fn row -> CaseMapping.normalize(get_in(row, ["channel", "name"]) || "") == channel_key end)

    owner_rows =
      if is_binary(uid) do
        user_rows = Enum.filter(projections.users, &(get_in(&1, ["user", "uid"]) == uid))
        membership_rows = Enum.filter(projections.memberships, &(&1["uid"] == uid))
        user_rows ++ membership_rows
      else
        []
      end

    rows = channel_rows ++ owner_rows ++ status_rows
    exists = channel_rows != []

    parts =
      [%{"phase" => "begin", "scope" => "channel", "channel" => channel_name}] ++
        Enum.map(Enum.chunk_every(rows, 256), &%{"phase" => "rows", "rows" => &1}) ++
        [%{"phase" => "end", "scope" => "channel", "rows" => length(rows), "exists" => exists}]

    {"OK", {:stream, parts}, state}
  end

  defp execute_snapshot(state, frame),
    do: {"UNSUPPORTED", Requests.failure_payload(frame, "UNSUPPORTED", "snapshot scope is not available"), state}

  defp normalize_callback_result({:ok, payload}) when is_map(payload), do: {:ok, payload}

  defp normalize_callback_result({:ok, payload, rows}) when is_map(payload) and is_list(rows),
    do: {:ok, payload, rows}

  defp normalize_callback_result({:async, job_fun}) when is_function(job_fun, 0), do: {:async, job_fun}

  defp normalize_callback_result({:async_deferred, job_fun}) when is_function(job_fun, 0),
    do: {:async_deferred, job_fun}

  defp normalize_callback_result({:ok, {:stream, parts}}) when is_list(parts) and parts != [],
    do: {:ok, {:stream, parts}}

  defp normalize_callback_result({:ok, {:stream, parts}, rows})
       when is_list(parts) and parts != [] and is_list(rows),
       do: {:ok, {:stream, parts}, rows}

  defp normalize_callback_result({:ok, status, payload}) when is_binary(status) and is_map(payload),
    do:
      if(Requests.valid_status?(status),
        do: {:ok, status, payload},
        else: {:error, "REJECTED", "invalid request status"}
      )

  defp normalize_callback_result({:error, status, message}) when is_binary(status) and is_binary(message),
    do: if(Requests.valid_status?(status), do: {:error, status, message}, else: {:error, "REJECTED", message})

  defp normalize_callback_result(_result), do: {:error, "REJECTED", "invalid request result"}

  defp execute_admin(state, frame, context) do
    case state.admin_fun do
      fun when is_function(fun, 3) ->
        case execute_callback(fun, frame, state.runtime, context) do
          {:ok, status, payload} -> {status, payload, state}
          {:ok, payload} -> {"OK", payload, state}
          {:error, status, message} -> {status, Requests.failure_payload(frame, status, message), state}
        end

      _ ->
        admin_default(state, frame)
    end
  end

  defp admin_default(state, %{"args" => %{"action" => "enable_edge", "neighbor_sid" => sid}} = frame) do
    case resolve_neighbor(state, sid) do
      {:ok, sid} ->
        next = %{state | disabled_edges: MapSet.delete(state.disabled_edges, sid)}
        next = if sid == state.parent_sid, do: schedule_parent(next, 0), else: next
        {"OK", Requests.ok_payload(%{"accepted" => true}), next}

      {:error, _} ->
        {"REJECTED", Requests.failure_payload(frame, "REJECTED", "neighbor is not configured"), state}
    end
  end

  defp admin_default(
         state,
         %{"args" => %{"action" => "disable_edge", "neighbor_sid" => sid, "reason" => reason}} = frame
       ) do
    case resolve_neighbor(state, sid) do
      {:ok, sid} ->
        next = %{state | disabled_edges: MapSet.put(state.disabled_edges, sid)}
        next = if sid == state.parent_sid, do: cancel_parent_timer(next), else: next

        if session = next.sessions_by_peer[sid], do: Session.close(session, "OPERATOR", safe_reason(reason))
        {"OK", Requests.ok_payload(%{"accepted" => true}), next}

      {:error, _} ->
        {"REJECTED", Requests.failure_payload(frame, "REJECTED", "neighbor is not configured"), state}
    end
  end

  defp admin_default(state, %{"args" => %{"action" => "rehash"}} = frame) do
    if is_pid(state.rehash_pid) do
      {"BUSY", Requests.failure_payload(frame, "BUSY", "configuration reload is already running"), state}
    else
      manager = self()
      rehash_fun = state.rehash_fun

      {pid, monitor_ref} =
        spawn_monitor(fn ->
          result =
            try do
              rehash_fun.()
            rescue
              _ -> {:error, :configuration_reload_failed}
            catch
              _kind, _reason -> {:error, :configuration_reload_failed}
            end

          send(manager, {:s2s_rehash_done, self(), result})
        end)

      next = %{state | rehash_pid: pid, rehash_monitor: monitor_ref}
      {"OK", Requests.ok_payload(%{"accepted" => true}), next}
    end
  end

  defp admin_default(state, %{"args" => %{"action" => action, "reason" => reason}})
       when action in ~w(restart shutdown) do
    send(self(), {:s2s_admin_lifecycle, action, reason})
    {"OK", Requests.ok_payload(%{"accepted" => true}), state}
  end

  defp admin_default(state, frame),
    do: {"REJECTED", Requests.failure_payload(frame, "REJECTED", "invalid administrative request"), state}

  defp execute_sasl(state, %{"args" => args} = frame, context) do
    key = {args["uid"], args["attempt_id"]}

    case args["phase"] do
      "abort" ->
        case state.sasl_attempts[key] do
          nil ->
            {"OK", Requests.sasl_payload("aborted", nil, nil, "ABORTED"), state}

          attempt ->
            if sasl_attempt_matches?(attempt, frame, args) do
              next = cancel_sasl_attempt(state, key, frame["request_id"])

              {"OK", Requests.sasl_payload("aborted", nil, nil, "ABORTED"), next}
            else
              {"STALE", Requests.failure_payload(frame, "STALE", "authentication attempt belongs to another origin"),
               state}
            end
        end

      "start" ->
        if Map.has_key?(state.sasl_attempts, key) do
          {"REJECTED", Requests.failure_payload(frame, "REJECTED", "authentication attempt already exists"), state}
        else
          max_attempts = value(section(state.s2s, :budgets), :max_pending_requests_node, 1_024)

          if map_size(state.sasl_attempts) >= max_attempts,
            do: {"BUSY", Requests.failure_payload(frame, "BUSY", "authentication capacity is exhausted"), state},
            else: start_sasl_attempt(state, key, args, frame["origin"])
        end

      "step" ->
        case state.sasl_attempts[key] do
          %{
            engine: %{mechanism: mechanism} = attempt,
            expires_at: expires_at,
            busy?: busy?
          } = saved ->
            if expires_at > Requests.monotonic_ms() do
              cond do
                not sasl_attempt_matches?(saved, frame, args) ->
                  {"STALE",
                   Requests.failure_payload(frame, "STALE", "authentication attempt belongs to another origin"), state}

                mechanism != args["mechanism"] ->
                  {"STALE", Requests.failure_payload(frame, "STALE", "authentication mechanism changed"), state}

                busy? ->
                  {"BUSY", Requests.failure_payload(frame, "BUSY", "authentication verification is in progress"), state}

                args["step"] != attempt.step + 1 ->
                  {"STALE", Requests.failure_payload(frame, "STALE", "authentication step is out of order"), state}

                true ->
                  continue_sasl_attempt(state, key, attempt, args, frame, context)
              end
            else
              {"STALE", Requests.failure_payload(frame, "STALE", "authentication attempt expired"),
               %{state | sasl_attempts: Map.delete(state.sasl_attempts, key)}}
            end

          _ ->
            {"STALE", Requests.failure_payload(frame, "STALE", "authentication attempt is unknown"), state}
        end
    end
  end

  defp start_sasl_attempt(state, key, args, origin) do
    options = Keyword.put(state.sasl_options, :generation, state.runtime.boot)

    with {:ok, attempt} <- SASL.start(args["uid"], args["attempt_id"], args["mechanism"], args["client_info"], options) do
      expires_at = Requests.monotonic_ms() + value(section(state.s2s, :timeouts), :request_ms, 15_000)

      next =
        %{
          state
          | sasl_attempts:
              Map.put(state.sasl_attempts, key, %{
                engine: attempt,
                expires_at: expires_at,
                busy?: false,
                origin: origin,
                client_info: args["client_info"]
              })
        }

      {"OK", Requests.sasl_payload("continue", nil, nil, "CONTINUE"), next}
    else
      {:error, _reason} ->
        {"OK", Requests.sasl_payload("failure", nil, nil, "REJECTED"), state}
    end
  end

  defp continue_sasl_attempt(state, key, attempt, args, frame, context) do
    options = Keyword.put(state.sasl_options, :generation, state.runtime.boot)

    case Pool.submit(state.sasl_pool, self(), fn -> SASL.step(attempt, args["data"], options) end) do
      {:ok, job_ref} ->
        expires_at = Requests.monotonic_ms() + value(section(state.s2s, :timeouts), :request_ms, 15_000)

        attempts =
          Map.update!(state.sasl_attempts, key, fn saved ->
            %{saved | engine: attempt, expires_at: expires_at, busy?: true}
          end)

        jobs =
          Map.put(state.sasl_jobs, job_ref, %{
            key: key,
            frame: frame,
            session: context[:request_session]
          })

        {:async, %{state | sasl_attempts: attempts, sasl_jobs: jobs}}

      :busy ->
        next = %{state | sasl_attempts: Map.delete(state.sasl_attempts, key)}

        {"BUSY", Requests.failure_payload(frame, "BUSY", "authentication verification is busy"), next}
    end
  end

  defp sasl_attempt_matches?(attempt, frame, args) do
    attempt[:origin] == frame["origin"] and attempt[:client_info] == args["client_info"]
  end

  defp finish_sasl_job(state, %{key: key, frame: frame, session: session} = _job, worker_result) do
    now = Requests.monotonic_ms()

    case state.sasl_attempts[key] do
      %{engine: _attempt, expires_at: expires_at, busy?: true} when expires_at > now ->
        {status, payload, next} = finish_sasl_step(state, key, worker_result)
        finish_admitted_request(next, session, frame, next.requests, status, payload, now)

      %{expires_at: expires_at, busy?: true} when expires_at <= now ->
        next = %{state | sasl_attempts: Map.delete(state.sasl_attempts, key)}

        finish_admitted_request(
          next,
          session,
          frame,
          next.requests,
          "TIMEOUT",
          Requests.failure_payload(frame, "TIMEOUT", "authentication attempt expired"),
          now
        )

      _ ->
        finish_admitted_request(
          state,
          session,
          frame,
          state.requests,
          "STALE",
          Requests.failure_payload(frame, "STALE", "authentication attempt expired"),
          now
        )
    end
  end

  defp finish_sasl_step(state, key, {:ok, {:continue, attempt, result}}) do
    expires_at = Requests.monotonic_ms() + value(section(state.s2s, :timeouts), :request_ms, 15_000)
    saved = Map.fetch!(state.sasl_attempts, key)

    next =
      %{
        state
        | sasl_attempts:
            Map.put(
              state.sasl_attempts,
              key,
              %{saved | engine: attempt, expires_at: expires_at, busy?: false}
            )
      }

    {"OK", Requests.sasl_payload("continue", result["challenge"] || "", nil, "CONTINUE"), next}
  end

  defp finish_sasl_step(state, key, {:ok, {:ok, _attempt, result}}) do
    next = %{state | sasl_attempts: Map.delete(state.sasl_attempts, key)}

    case sasl_binding(state, result) do
      nil -> {"OK", Requests.sasl_payload("failure", nil, nil, "STALE_POLICY"), next}
      binding -> {"OK", Requests.sasl_payload("success", nil, binding, "OK"), next}
    end
  end

  defp finish_sasl_step(state, key, {:ok, {:error, _reason}}) do
    next = %{state | sasl_attempts: Map.delete(state.sasl_attempts, key)}
    {"OK", Requests.sasl_payload("failure", nil, nil, "REJECTED"), next}
  end

  defp finish_sasl_step(state, key, {:error, _reason}) do
    next = %{state | sasl_attempts: Map.delete(state.sasl_attempts, key)}
    {"BUSY", Requests.error_payload("BUSY", "authentication verification is busy"), next}
  end

  defp sasl_binding(state, %{"account_id" => account_id}) do
    with true <- ElixIRCd.Server.S2S.Policy.grant_ready?(state.runtime.policy),
         {:ok, account} <- ElixIRCd.Server.S2S.Policy.get(state.runtime.policy, "account", account_id) do
      %{
        "account_id" => account_id,
        "auth_epoch" => account["auth_epoch"],
        "policy_epoch" => state.runtime.policy.epoch
      }
    else
      _ -> nil
    end
  end

  defp sasl_binding(_state, _result), do: nil

  defp expire_sasl_attempts(attempts, now_ms) do
    Enum.reduce(attempts, {%{}, []}, fn {key, attempt}, {kept, expired} ->
      if attempt[:expires_at] <= now_ms,
        do: {kept, [key | expired]},
        else: {Map.put(kept, key, attempt), expired}
    end)
  end

  defp cancel_expired_sasl_jobs(jobs, expired_request_ids, pool) do
    expired_request_ids = MapSet.new(expired_request_ids)

    Enum.reduce(jobs, %{}, fn {job_ref, job}, kept ->
      if MapSet.member?(expired_request_ids, job.frame["request_id"]) do
        _ = Pool.cancel(pool, job_ref)
        kept
      else
        Map.put(kept, job_ref, job)
      end
    end)
  end

  defp expire_sasl_attempt_jobs(state, expired_keys, now) do
    expired_keys = MapSet.new(expired_keys)

    Enum.reduce(state.sasl_jobs, state, fn {job_ref, job}, current ->
      if MapSet.member?(expired_keys, job[:key]) do
        _ = Pool.cancel(current.sasl_pool, job_ref)

        {:noreply, updated} =
          finish_admitted_request(
            current,
            job[:session],
            job[:frame],
            current.requests,
            "TIMEOUT",
            Requests.failure_payload(job[:frame], "TIMEOUT", "authentication attempt expired"),
            now
          )

        %{updated | sasl_jobs: Map.delete(updated.sasl_jobs, job_ref)}
      else
        current
      end
    end)
  end

  defp cancel_sasl_attempt(state, key, except_request_id) do
    job_request_ids =
      state.sasl_jobs
      |> Enum.filter(fn {_job_ref, job} -> job[:key] == key end)
      |> Enum.map(fn {_job_ref, job} -> get_in(job, [:frame, "request_id"]) end)

    pending_request_ids =
      state.requests.pending
      |> Enum.flat_map(fn {_request_key, %{frame: frame}} ->
        if sasl_request_for_attempt?(frame, key) and frame["request_id"] != except_request_id do
          [frame["request_id"]]
        else
          []
        end
      end)

    request_ids = job_request_ids ++ pending_request_ids

    state
    |> cancel_sasl_request_ids(request_ids)
    |> Map.update!(:sasl_attempts, &Map.delete(&1, key))
  end

  defp sasl_request_for_attempt?(%{"method" => "sasl", "args" => args}, {uid, attempt_id})
       when is_map(args),
       do: args["uid"] == uid and args["attempt_id"] == attempt_id

  defp sasl_request_for_attempt?(_frame, _key), do: false

  defp cancel_sasl_request_jobs(jobs, request_ids, pool) do
    Enum.reduce(jobs, %{}, fn {job_ref, job}, kept ->
      if MapSet.member?(request_ids, get_in(job, [:frame, "request_id"])) do
        _ = Pool.cancel(pool, job_ref)
        kept
      else
        Map.put(kept, job_ref, job)
      end
    end)
  end

  defp execute_request_fun(fun, frame, runtime, context) when is_function(fun, 3) do
    normalize_request_result(fun.(frame, runtime, context))
  rescue
    _ -> {"REJECTED", Requests.error_payload("REJECTED", "request execution failed")}
  end

  defp execute_request_fun(nil, %{"method" => "query", "args" => args}, runtime, _context),
    do: execute_local_query(args, runtime)

  defp execute_request_fun(nil, _frame, _runtime, _context),
    do: {"UNSUPPORTED", Requests.error_payload("UNSUPPORTED", "request execution is not configured")}

  defp execute_request_fun(_fun, _frame, _runtime, _context),
    do: {"UNSUPPORTED", Requests.error_payload("UNSUPPORTED", "request method is not enabled")}

  defp execute_local_query(
         %{"command" => "WHOIS", "params" => _params, "target_uid" => target_uid, "view" => "owner_detail"},
         runtime
       )
       when is_binary(target_uid) do
    case runtime.users[target_uid] do
      %{"uid" => ^target_uid, "signon_ms" => signon_ms, "secure_client" => secure_client} ->
        result = %{
          "uid" => target_uid,
          "signon_ms" => signon_ms,
          "idle_ms" => nil,
          "secure_client" => secure_client
        }

        {"OK", Requests.ok_payload(result)}

      _ ->
        {"NOT_FOUND", Requests.error_payload("NOT_FOUND", "user is not available")}
    end
  end

  defp execute_local_query(%{"command" => command, "params" => params, "target_uid" => target_uid}, runtime) do
    users =
      case target_uid do
        uid when is_binary(uid) -> if(runtime.users[uid], do: [runtime.users[uid]], else: [])
        _ -> Map.values(runtime.users) |> Enum.sort_by(& &1["uid"]) |> Enum.take(256)
      end

    result = %{
      "command" => command,
      "params" => params,
      "server" => runtime.sid,
      "users" =>
        Enum.map(
          users,
          &Map.take(&1, [
            "uid",
            "home",
            "requested_nick",
            "effective_nick",
            "ident",
            "displayhost",
            "realname",
            "oper_role",
            "away"
          ])
        )
    }

    {"OK", Requests.ok_payload(result)}
  end

  defp normalize_request_result({:ok, payload}) when is_map(payload), do: {"OK", payload}

  defp normalize_request_result({:ok, status, payload}) when is_binary(status) and is_map(payload) do
    if Requests.valid_status?(status),
      do: {status, payload},
      else: {"REJECTED", Requests.error_payload("REJECTED", "invalid request status")}
  end

  defp normalize_request_result({:error, status, message}) when is_binary(status) and is_binary(message),
    do:
      if(Requests.valid_status?(status),
        do: {status, Requests.error_payload(status, message)},
        else: {"REJECTED", Requests.error_payload("REJECTED", message)}
      )

  defp normalize_request_result(_result), do: {"REJECTED", Requests.error_payload("REJECTED", "invalid request result")}

  defp accept_hello(state, record, frame) do
    peer_sid = record.peer_sid
    peer_row = Enum.find(state.roster, &(&1.sid == peer_sid))

    relation? =
      case record.direction do
        :incoming -> peer_row && peer_row.parent == state.runtime.sid
        :outgoing -> Tree.parent(state.roster, state.runtime.sid) == {:ok, peer_sid}
        _ -> false
      end

    cond do
      not relation? ->
        {:error, :invalid_tree_direction}

      frame["sid"] != peer_sid ->
        {:error, :certificate_sid_mismatch}

      peer_row == nil or frame["name"] != peer_row.name ->
        {:error, :hello_name_mismatch}

      not Identity.valid_id?(frame["boot"]) ->
        {:error, :invalid_peer_boot}

      Map.has_key?(state.sessions_by_peer, peer_sid) and
          state.sessions_by_peer[peer_sid] != record_session(state, record) ->
        {:error, :duplicate_edge}

      true ->
        with {:ok, edge_id} <- Identity.edge_id(record.local_hello, frame),
             {:ok, runtime} <-
               Runtime.learn_node(state.runtime, %{
                 "sid" => peer_sid,
                 "boot" => frame["boot"],
                 "name" => frame["name"],
                 "description" => ""
               }),
             topology <- topology_row(state, peer_sid, frame, edge_id),
             {:ok, runtime, _effects} <- Runtime.apply_local_row(runtime, topology) do
          session = session_for_record(state, record)
          next_record = %{record | status: :syncing, edge_id: edge_id, remote_hello: frame}
          next = put_session(%{state | runtime: runtime}, session, next_record)
          next = broadcast_frame(next, topology_state_frame(next), session)
          {:ok, next, edge_id}
        end
    end
  end

  defp topology_row(state, peer_sid, frame, edge_id) do
    local = Map.fetch!(state.runtime.nodes, state.runtime.sid)

    endpoints =
      [
        %{"sid" => state.runtime.sid, "boot" => state.runtime.boot},
        %{"sid" => peer_sid, "boot" => frame["boot"]}
      ]
      |> Enum.sort_by(& &1["sid"])

    [a, b] = endpoints

    %{
      "kind" => "topology.add",
      "nodes" => [local, %{"sid" => peer_sid, "boot" => frame["boot"], "name" => frame["name"], "description" => ""}],
      "edges" => [
        %{
          "id" => edge_id,
          "a" => a,
          "b" => b,
          "ready_sides" => []
        }
      ]
    }
  end

  defp mark_edge_ready(state, _session, %{edge_id: edge_id}) when is_binary(edge_id) do
    case state.runtime.edges[edge_id] do
      %{ready_sides: ready} ->
        if state.runtime.sid in ready do
          state
        else
          previous_runtime = state.runtime
          old_capability_maps = capture_dynamic_capabilities(previous_runtime)
          row = %{"kind" => "topology.ready", "edge_id" => edge_id, "side" => state.runtime.sid}

          case Runtime.apply_local_row(state.runtime, row) do
            {:ok, runtime, _effects} ->
              next = %{state | runtime: runtime}
              next = maybe_notify_dynamic_capabilities(next, previous_runtime, old_capability_maps)
              broadcast_frame(next, state_frame(next, row), nil)

            {:error, _reason} ->
              state
          end
        end

      _ ->
        state
    end
  end

  defp mark_edge_ready(state, _session, _record), do: state

  defp cleanup_session(state, session, reason) do
    case Map.pop(state.sessions, session) do
      {nil, _} ->
        state

      {record, sessions} ->
        previous_runtime = state.runtime
        old_capability_maps = capture_dynamic_capabilities(previous_runtime)
        peers = Map.delete(state.sessions_by_peer, record.peer_sid)

        state = %{
          state
          | sessions: sessions,
            sessions_by_peer: peers,
            last_link_error: safe_reason(reason)
        }

        state = cancel_sync_jobs_for_session(state, session, record.generation)

        state =
          if record.edge_id do
            row = %{
              "kind" => "topology.remove",
              "edge_id" => record.edge_id,
              "reporter" => state.runtime.sid,
              "reason" => safe_reason(reason)
            }

            case Runtime.apply_local_row(state.runtime, row) do
              {:ok, runtime, _effects} ->
                next = Map.put(state, :runtime, runtime)
                next = maybe_notify_dynamic_capabilities(next, previous_runtime, old_capability_maps)
                broadcast_frame(next, state_frame(next, row), session)

              _ ->
                state
            end
          else
            state
          end

        state = cancel_session_repairs(state, session, record.generation)
        state = cancel_link_requests(state, record.peer_sid)

        state =
          if record.owner == state.parent_connector,
            do: %{state | connector_error: safe_reason(reason)},
            else: state

        state =
          if state.stable_timer && record.owner == state.parent_connector,
            do: cancel_stable_timer(state),
            else: state

        cond do
          record.owner != state.parent_connector ->
            state

          state.lifecycle == :closing ->
            %{state | parent_connector: nil}

          true ->
            next = %{state | parent_connector: nil}

            if permanent_link_error?(reason),
              do: %{next | retry_blocked?: true},
              else: schedule_parent(next, reconnect_delay(next, reason))
        end
    end
  end

  defp cancel_session_repairs(state, session, generation) do
    channel_keys =
      state.channel_repairs
      |> Enum.filter(fn {_key, repair} -> repair.session == session and repair.generation == generation end)
      |> Enum.map(&elem(&1, 0))

    policy_keys =
      state.policy_repairs
      |> Enum.filter(fn {_key, repair} -> repair.session == session and repair.generation == generation end)
      |> Enum.map(&elem(&1, 0))

    request_ids =
      state.channel_repairs
      |> Enum.filter(fn {_key, repair} -> repair.session == session and repair.generation == generation end)
      |> Enum.map(fn {_key, repair} -> repair.request_id end)

    request_ids =
      state.policy_repairs
      |> Enum.filter(fn {_key, repair} -> repair.session == session and repair.generation == generation end)
      |> Enum.map(fn {_key, repair} -> repair.request_id end)
      |> then(&(request_ids ++ &1))

    state
    |> cancel_request_ids(request_ids, "link generation closed")
    |> then(
      &%{
        &1
        | channel_repairs: Map.drop(&1.channel_repairs, channel_keys),
          policy_repairs: Map.drop(&1.policy_repairs, policy_keys)
      }
    )
  end

  defp cancel_sync_jobs_for_session(state, session, generation) do
    {cancelled, remaining} =
      Enum.split_with(state.sync_jobs, fn {_ref, job} ->
        job.session == session and job.generation == generation
      end)

    Enum.each(cancelled, fn {_ref, job} ->
      if is_pid(job.pid), do: Process.exit(job.pid, :shutdown)
      if is_reference(job.monitor_ref), do: Process.demonitor(job.monitor_ref, [:flush])
    end)

    %{state | sync_jobs: Map.new(remaining)}
  end

  defp start_parent_connector(state) do
    if state.parent_sid && parent_configured?(state) do
      options = [manager: self(), config: state.config, peer_sid: state.parent_sid, generation: Identity.nonce()]

      case DynamicSupervisor.start_child(
             ElixIRCd.Server.S2S.ConnectorSupervisor,
             {ElixIRCd.Server.S2S.Connector, options}
           ) do
        {:ok, pid} -> %{state | parent_connector: pid, reconnect_attempt: state.reconnect_attempt + 1}
        {:error, _} -> schedule_parent(state, reconnect_delay(state, :start_failed))
      end
    else
      state
    end
  end

  defp schedule_parent(%{parent_sid: nil} = state, _delay), do: state
  defp schedule_parent(%{retry_blocked?: true} = state, _delay), do: state

  defp schedule_parent(state, delay) do
    if state.parent_timer, do: Process.cancel_timer(state.parent_timer)
    timer = Process.send_after(self(), :connect_parent, max(delay, 0))
    %{state | parent_timer: timer}
  end

  defp reconnect_delay(state, _reason) do
    reconnect = section(state.s2s, :reconnect)
    initial = value(reconnect, :initial_ms, 1_000)
    maximum = value(reconnect, :max_ms, 60_000)
    exponent = min(state.reconnect_attempt, 16)
    base = min(maximum, initial * trunc(:math.pow(2, exponent)))
    jitter = value(reconnect, :jitter_ms, div(base, 4))
    max(0, min(maximum, base + if(jitter > 0, do: :rand.uniform(jitter * 2 + 1) - jitter, else: 0)))
  end

  defp permanent_link_error?(reason) do
    reason
    |> inspect()
    |> String.downcase()
    |> then(&(String.contains?(&1, "certificate") or String.contains?(&1, "profile") or String.contains?(&1, "auth")))
  end

  defp incoming_peer(state, peer_info) do
    certfp = peer_info[:certfp] || peer_info["certfp"]
    address = peer_info[:address] || peer_info["address"]
    children = value(state.s2s, :children, %{})

    Enum.find_value(children, {:error, :peer_certificate_not_pinned}, fn {sid, child} ->
      pins = value(child, :pins, [])
      ips = value(child, :ips, [])
      row = Enum.find(state.roster, &(&1.sid == sid))

      if (row && not MapSet.member?(state.disabled_edges, sid)) and
           Tree.initiator_allowed?(state.roster, sid, state.runtime.sid) and TLS.pin_allowed?(certfp, pins) and
           TLS.address_allowed?(address, ips),
         do: {:ok, %{sid: sid, name: row.name, pins: pins}}
    end)
  end

  defp parent_pins(state), do: state.s2s |> value(:parent_connection, []) |> value(:pins, [])

  defp parent_configured?(state),
    do: is_list(value(state.s2s, :parent_connection, nil)) or is_map(value(state.s2s, :parent_connection, nil))

  defp direct_neighbor?(state, peer_sid), do: peer_sid in Tree.neighbors(state.roster, state.runtime.sid)

  defp resolve_neighbor(state, target) when is_binary(target) do
    case Enum.find(state.roster, fn row -> row.sid == target or row.name == target end) do
      %{sid: sid} ->
        if sid in Tree.neighbors(state.roster, state.runtime.sid),
          do: {:ok, sid},
          else: {:error, :unconfigured_neighbor}

      _ ->
        {:error, :unconfigured_neighbor}
    end
  end

  defp resolve_neighbor(_state, _target), do: {:error, :unconfigured_neighbor}

  defp cancel_parent_timer(state) do
    Process.cancel_timer(state.parent_timer)
    %{state | parent_timer: nil}
  end

  defp schedule_stable_reset(state, _session, %{owner: owner}) when owner != state.parent_connector, do: state

  defp schedule_stable_reset(state, session, %{generation: generation}) do
    state = cancel_stable_timer(state)
    reconnect = section(state.s2s, :reconnect)
    delay = max(value(reconnect, :stable_ms, 30_000), 1)
    timer = Process.send_after(self(), {@stable_active_message, session, generation}, delay)
    %{state | stable_timer: timer}
  end

  defp cancel_stable_timer(%{stable_timer: nil} = state), do: state

  defp cancel_stable_timer(state) do
    Process.cancel_timer(state.stable_timer)
    %{state | stable_timer: nil}
  end

  defp close_link_generations(state, reason, options \\ []) do
    state = cancel_all_sync_jobs(state)
    state = if Keyword.get(options, :drain?, true), do: drain_link_output(state), else: state

    Enum.each(state.sessions, fn {session, _record} ->
      if is_pid(session) do
        try do
          Session.close(session, "TRANSPORT", reason)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    if is_pid(state.parent_connector) and Process.alive?(state.parent_connector) do
      timeout = max(value(section(state.s2s, :timeouts), :shutdown_ms, 15_000), 1)

      try do
        GenServer.stop(state.parent_connector, :normal, timeout)
      catch
        :exit, _ -> :ok
      end
    end

    state
  end

  defp close_uncertain_link_generations(state, scope, reason) do
    case uncertain_output_peers(state, scope) do
      :all ->
        close_link_generations(state, reason, drain?: false)

      [] ->
        state

      peers ->
        Enum.each(state.sessions, fn {session, record} ->
          if record.peer_sid in peers do
            try do
              Session.close(session, "TRANSPORT", reason)
            catch
              :exit, _ -> :ok
            end
          end
        end)

        state
    end
  end

  defp output_destination_scope(%{destinations: destinations})
       when is_list(destinations) and destinations != [],
       do: destinations

  defp output_destination_scope(_group), do: :all

  defp uncertain_output_peers(_state, :all), do: :all

  defp uncertain_output_peers(state, destinations) when is_list(destinations) do
    cond do
      Enum.any?(destinations, &(&1 in [:global, :s2s_all])) ->
        :all

      true ->
        destinations
        |> Enum.flat_map(fn
          {:s2s_peer, peer_sid} when is_binary(peer_sid) ->
            [peer_sid]

          {:s2s_target, target_sid} when is_binary(target_sid) ->
            case Tree.next_hop(state.roster, state.runtime.sid, target_sid) do
              {:ok, peer_sid} when peer_sid != state.runtime.sid -> [peer_sid]
              _ -> []
            end

          _ ->
            []
        end)
        |> Enum.uniq()
    end
  end

  defp begin_shutdown(state, reason \\ "server shutdown") do
    timeout = max(value(section(state.s2s, :timeouts), :shutdown_ms, 15_000), 1)

    state = %{
      state
      | lifecycle: :closing,
        heartbeat_timer: cancel_timer(state.heartbeat_timer),
        parent_timer: cancel_timer(state.parent_timer),
        stable_timer: cancel_timer(state.stable_timer)
    }

    stop_service_jobs(state.service_jobs)
    state = stop_rehash_job(state)

    if is_pid(state.sasl_pool) and Process.alive?(state.sasl_pool) do
      try do
        Pool.stop(state.sasl_pool)
      catch
        :exit, _ -> :ok
      end
    end

    next = close_link_generations(state, reason)
    timer = Process.send_after(self(), @finish_shutdown_message, timeout)
    %{next | shutdown_timer: timer}
  end

  defp lifecycle_reason("restart", reason), do: "server restart: " <> safe_reason(reason)
  defp lifecycle_reason("shutdown", reason), do: "server shutdown: " <> safe_reason(reason)

  defp finish_rehash(state) do
    if is_reference(state.rehash_monitor), do: Process.demonitor(state.rehash_monitor, [:flush])
    %{state | rehash_pid: nil, rehash_monitor: nil}
  end

  defp stop_rehash_job(state) do
    if is_pid(state.rehash_pid), do: Process.exit(state.rehash_pid, :shutdown)
    if is_reference(state.rehash_monitor), do: Process.demonitor(state.rehash_monitor, [:flush])
    %{state | rehash_pid: nil, rehash_monitor: nil}
  end

  defp invoke_lifecycle(%{lifecycle_fun: fun}, action, reason) when is_function(fun, 2) do
    spawn(fn ->
      try do
        fun.(action, reason)
      rescue
        _ -> :ok
      catch
        _kind, _reason -> :ok
      end
    end)

    :ok
  end

  defp invoke_lifecycle(_state, action, reason) do
    spawn(fn ->
      Process.sleep(100)

      case action do
        "restart" ->
          _ = Application.stop(:elixircd)
          _ = Application.start(:elixircd)

        "shutdown" ->
          _ = Application.stop(:elixircd)
      end

      _ = reason
    end)

    :ok
  end

  defp cancel_timer(nil), do: nil

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    nil
  end

  defp stop_service_jobs(jobs) when is_map(jobs) do
    Enum.each(jobs, fn
      {_job_ref, %{pid: pid}} when is_pid(pid) -> Process.exit(pid, :shutdown)
      _ -> :ok
    end)

    :ok
  end

  defp stop_service_jobs(_jobs), do: :ok

  defp stop_sync_jobs(jobs) when is_map(jobs) do
    Enum.each(jobs, fn
      {_job_ref, %{pid: pid, monitor_ref: monitor_ref}} ->
        if is_pid(pid), do: Process.exit(pid, :shutdown)
        if is_reference(monitor_ref), do: Process.demonitor(monitor_ref, [:flush])

      _ ->
        :ok
    end)

    :ok
  end

  defp stop_sync_jobs(_jobs), do: :ok

  defp cancel_all_sync_jobs(state) do
    stop_sync_jobs(state.sync_jobs)
    %{state | sync_jobs: %{}}
  end

  defp drain_link_output(state) do
    budget = max(value(section(state.s2s, :budgets), :aggregate_output_bytes, 128 * 1_048_576), 0)

    {next, _remaining} =
      Enum.reduce(state.sessions, {state, budget}, fn {session, record}, {current, remaining} ->
        bytes = record.pending_bytes || 0

        cond do
          bytes == 0 or record.pending == [] or bytes > remaining or record.status not in [:syncing, :active] ->
            {current, remaining}

          true ->
            case send_frames(session, Enum.reverse(record.pending)) do
              :ok ->
                {put_session(current, session, %{record | pending: [], pending_bytes: 0}), remaining - bytes}

              {:error, reason} ->
                Session.close(session, "RESOURCE", safe_reason(reason))
                {cleanup_session(current, session, reason), remaining}
            end
        end
      end)

    next
  end

  defp connect_parent(%{parent_connector: pid} = state) when is_pid(pid) do
    if Process.alive?(pid),
      do: {:noreply, state},
      else: {:noreply, start_parent_connector(%{state | parent_connector: nil})}
  end

  defp connect_parent(state), do: {:noreply, start_parent_connector(state)}

  defp session_for_record(state, record),
    do: Enum.find_value(state.sessions, fn {pid, value} -> if value == record, do: pid end)

  defp record_session(state, record), do: session_for_record(state, record)

  defp put_session(state, session, record), do: %{state | sessions: Map.put(state.sessions, session, record)}

  defp pending_link_queue_totals(state) do
    Enum.reduce(state.sessions, {0, 0}, fn {_session, record}, {frames, bytes} ->
      {frames + length(record.pending || []), bytes + (record.pending_bytes || 0)}
    end)
  end

  defp pending_sync_queue_totals(state) do
    Enum.reduce(state.sessions, {0, 0}, fn {_session, record}, {frames, bytes} ->
      {frames + length(record.pending_state || []), bytes + (record.pending_state_bytes || 0)}
    end)
  end

  # Queue admission needs a bounded estimate while the Manager owns its state.
  # The Session process performs the canonical JSON encoding and enforces the
  # exact wire-byte limit when it accepts the frame.
  defp frame_budget_bytes(term), do: 64 + frame_term_bytes(term)

  defp frame_term_bytes(term) when is_binary(term), do: 16 + byte_size(term) * 2
  defp frame_term_bytes(term) when is_integer(term), do: 16
  defp frame_term_bytes(term) when is_float(term), do: 24
  defp frame_term_bytes(nil), do: 16
  defp frame_term_bytes(term) when is_atom(term), do: 24

  defp frame_term_bytes(term) when is_map(term) do
    64 +
      Enum.reduce(Map.to_list(term), 0, fn {key, value}, bytes ->
        bytes + 24 + frame_term_bytes(key) + frame_term_bytes(value)
      end)
  end

  defp frame_term_bytes(term) when is_list(term) do
    24 + Enum.reduce(term, 0, fn value, bytes -> bytes + frame_term_bytes(value) end)
  end

  defp frame_term_bytes(_term), do: 32

  defp safe_reason({:session_down, {:protocol, reason}}), do: "session protocol: " <> safe_reason(reason)

  defp safe_reason({:session_down, {:peer_close, code}}) when is_binary(code),
    do: "peer_close: " <> String.slice(code, 0, 128)

  defp safe_reason({:peer_close, code}) when is_binary(code), do: "peer_close: " <> String.slice(code, 0, 128)
  defp safe_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 512)
  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({tag, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp safe_reason(_reason), do: "link closed"

  defp observe_frame_stamps(%{"changes" => changes}) when is_list(changes),
    do: Output.observe_stamps(stamps_from_rows(changes))

  defp observe_frame_stamps(_frame), do: :ok

  defp stamps_from_rows(rows) when is_list(rows) do
    for %{"stamp" => stamp} <- rows, is_list(stamp), do: stamp
  end

  defp section(config, key) when is_map(config), do: Map.get(config, key, Map.get(config, Atom.to_string(key), %{}))
  defp section(config, key) when is_list(config), do: Keyword.get(config, key, [])
  defp section(_config, _key), do: []

  defp value(section, key, default) when is_map(section),
    do: Map.get(section, key, Map.get(section, Atom.to_string(key), default))

  defp value(section, key, default) when is_list(section), do: Keyword.get(section, key, default)
  defp value(_section, _key, default), do: default

  defp publish_identity(config, runtime) do
    Application.put_env(:elixircd, :s2s, section(config, :s2s))
    Application.put_env(:elixircd, :s2s_boot, runtime.boot)
    :ok
  end
end
