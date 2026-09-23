defmodule ElixIRCd.Server.S2S.Listener do
  @moduledoc "Dedicated mutual-TLS ENP/1 incoming connection handler."

  use ThousandIsland.Handler

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.Protocol
  alias ElixIRCd.Server.S2S.Session
  alias ElixIRCd.Server.S2S.TLS

  @max_pending_session_events 8

  @impl ThousandIsland.Handler
  def handle_connection(socket, options) when is_map(options) do
    manager = Map.fetch!(options, :manager)
    config = Map.fetch!(options, :config)

    with {:ok, peer_info} <- TLS.peer_info(ThousandIsland.Socket, socket),
         {:ok, peer} <- Manager.admit_peer(manager, :incoming, peer_info),
         local_hello <- Manager.local_hello(manager),
         generation <- Identity.nonce(),
         {:ok, session} <-
           Session.start_link(
             local_hello: local_hello,
             generation: generation,
             hello_timeout_ms: timeout(config, :tls_hello_ms, 15_000),
             incomplete_frame_ms: timeout(config, :incomplete_frame_ms, 15_000),
             max_body: max_frame(config),
             max_outbound_frames: max_pending_frames(config),
             max_outbound_bytes: per_link_queue_bytes(config),
             send_fun: send_fun(self()),
             notify: self(),
             tls_established: false
           ),
         {:ok, _} <-
           Manager.register_session(manager, session, %{
             direction: :incoming,
             peer_sid: peer.sid,
             peer_name: peer.name,
             peer_info: peer_info,
             owner: self(),
             generation: generation,
             local_hello: local_hello
           }) do
      monitor = Process.monitor(session)
      Process.unlink(session)
      Session.set_admission_fun(session, fn frame -> Manager.admit_hello(manager, session, frame) end)
      Session.tls_established(session)

      {:continue,
       %{
         manager: manager,
         config: config,
         session: session,
         monitor: monitor,
         peer_info: peer_info,
         peer_sid: peer.sid,
         generation: generation,
         receive_pid: nil,
         receive_ref: nil,
         receive_monitor: nil,
         receive_queue: :queue.new(),
         receive_queue_bytes: 0,
         receive_in_flight_bytes: 0,
         receive_buffer_bytes: 0,
         max_receive_queue_bytes: max_inbound_queue_bytes(config),
         session_event_queue: :queue.new(),
         session_event_ref: nil,
         session_event_timer: nil,
         awaiting_manager?: false,
         manager_event_ack_before_receive?: false,
         quit_reason: nil
       }}
    else
      {:error, reason} ->
        send_admission_close(socket, reason)
        {:close, %{}}

      _ ->
        send_admission_close(socket, :peer_admission_rejected)
        {:close, %{}}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, _socket, state) when is_binary(data) do
    cond do
      byte_size(data) > state.max_receive_queue_bytes ->
        {:close, state}

      can_start_receive?(state) ->
        {:continue, start_receive_worker(state, state.session, data)}

      true ->
        case enqueue_receive_data(state, data) do
          {:ok, next} -> {:continue, next}
          {:error, _reason} -> {:close, state}
        end
    end
  end

  @impl GenServer
  def handle_call({:s2s_send, wire}, _from, {socket, state}) when is_binary(wire) do
    case ThousandIsland.Socket.send(socket, wire) do
      :ok ->
        {:reply, :ok, {socket, state}}

      {:error, reason} ->
        Manager.link_closed(state.manager, state.session, {:send_error, reason})
        {:reply, {:error, reason}, {socket, state}}
    end
  end

  def handle_call({:s2s_send, _wire}, _from, {socket, state}),
    do: {:reply, {:error, :socket_not_ready}, {socket, state}}

  @impl GenServer
  def handle_info(
        {:s2s_receive_result, ref, result, buffer_bytes},
        {socket, %{receive_ref: ref, receive_monitor: monitor} = state}
      ) do
    Process.demonitor(monitor, [:flush])
    state = clear_receive_worker(%{state | receive_buffer_bytes: buffer_bytes})

    case result do
      :ok ->
        resume_receive(socket, %{state | awaiting_manager?: false, manager_event_ack_before_receive?: false})

      :manager_pending ->
        state = %{state | awaiting_manager?: true}

        if state.manager_event_ack_before_receive? and not manager_event_pending?(state) do
          next = %{state | awaiting_manager?: false, manager_event_ack_before_receive?: false}
          {:noreply, {socket, start_receive_worker(next, next.session, <<>>)}}
        else
          {:noreply, {socket, state}}
        end

      {:error, reason} ->
        {:stop, {:receive_error, reason}, {socket, state}}
    end
  end

  def handle_info(
        {:s2s_manager_event_ack, ref, status},
        {socket, %{session_event_ref: ref} = state}
      ) do
    case status do
      :ok -> complete_manager_event(socket, state)
      :stale -> stop_link(socket, state, :stale_session_generation)
      :closing -> stop_link(socket, state, :manager_shutting_down)
      _ -> stop_link(socket, state, :invalid_manager_ack)
    end
  end

  def handle_info({:s2s_manager_event_ack, _ref, _status}, {socket, state}), do: {:noreply, {socket, state}}

  def handle_info(
        {:s2s_manager_event_timeout, ref},
        {socket, %{session_event_ref: ref} = state}
      ),
      do: stop_link(socket, state, :manager_event_timeout)

  def handle_info({:s2s_manager_event_timeout, _ref}, {socket, state}), do: {:noreply, {socket, state}}

  def handle_info(
        {:DOWN, monitor, :process, _worker, reason},
        {socket, %{receive_monitor: monitor} = state}
      ) do
    {:stop, {:receive_worker_down, reason}, {socket, state}}
  end

  def handle_info({:s2s_session, session, generation, event}, {socket, %{session: session} = state}) do
    queue_session_event(socket, state, generation, event)
  end

  def handle_info({:DOWN, monitor, :process, session, reason}, {socket, %{monitor: monitor, session: session} = state}) do
    Manager.link_closed(state.manager, session, reason)
    {:stop, {:session_down, reason}, {socket, state}}
  end

  def handle_info(_message, {socket, state}), do: {:noreply, {socket, state}}

  @impl ThousandIsland.Handler
  def handle_error(_reason, _socket, []), do: :ok

  def handle_error(reason, _socket, state) do
    stop_receive_worker(state)
    if is_reference(state.session_event_timer), do: Process.cancel_timer(state.session_event_timer)
    Manager.link_closed(state.manager, state.session, {:socket_error, reason})
  end

  @impl ThousandIsland.Handler
  def handle_timeout(_socket, []), do: :ok

  def handle_timeout(_socket, state) do
    stop_receive_worker(state)
    if is_reference(state.session_event_timer), do: Process.cancel_timer(state.session_event_timer)
    Session.close(state.session, "TIMEOUT", "transport timeout")
    Manager.link_closed(state.manager, state.session, :timeout)
  end

  @impl ThousandIsland.Handler
  def handle_shutdown(_socket, []), do: :ok

  def handle_shutdown(_socket, state) do
    stop_receive_worker(state)
    if is_reference(state.session_event_timer), do: Process.cancel_timer(state.session_event_timer)
    Session.close(state.session, "TRANSPORT", "server shutdown")
    Manager.link_closed(state.manager, state.session, :shutdown)
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, []), do: :ok

  def handle_close(_socket, state) do
    stop_receive_worker(state)
    if is_reference(state.session_event_timer), do: Process.cancel_timer(state.session_event_timer)
    Manager.link_closed(state.manager, state.session, state.quit_reason || :closed)
  end

  defp send_fun(handler),
    do: fn wire ->
      try do
        GenServer.call(handler, {:s2s_send, wire}, 15_000)
      catch
        :exit, reason -> {:error, {:transport, reason}}
      end
    end

  defp queue_session_event(socket, state, generation, event) do
    if :queue.len(state.session_event_queue) >= @max_pending_session_events do
      stop_link(socket, state, :manager_event_queue_overrun)
    else
      queue = :queue.in({generation, event}, state.session_event_queue)
      {:noreply, {socket, dispatch_manager_event(%{state | session_event_queue: queue})}}
    end
  end

  defp dispatch_manager_event(%{session_event_ref: nil} = state) do
    case :queue.out(state.session_event_queue) do
      {{:value, {generation, event}}, rest} ->
        ref = make_ref()
        timer = Process.send_after(self(), {:s2s_manager_event_timeout, ref}, manager_event_timeout_ms(state))

        send(
          state.manager,
          {:s2s_session_event, state.session, generation, event, self(), state.peer_info, ref}
        )

        %{
          state
          | session_event_queue: rest,
            session_event_ref: ref,
            session_event_timer: timer
        }

      {:empty, _queue} ->
        state
    end
  end

  defp dispatch_manager_event(state), do: state

  defp complete_manager_event(socket, state) do
    if is_reference(state.session_event_timer), do: Process.cancel_timer(state.session_event_timer)

    state = %{state | session_event_ref: nil, session_event_timer: nil}
    state = dispatch_manager_event(state)

    cond do
      manager_event_pending?(state) ->
        {:noreply, {socket, state}}

      is_pid(state.receive_pid) ->
        {:noreply, {socket, %{state | manager_event_ack_before_receive?: true}}}

      state.awaiting_manager? ->
        next = %{state | awaiting_manager?: false, manager_event_ack_before_receive?: false}
        {:noreply, {socket, start_receive_worker(next, next.session, <<>>)}}

      true ->
        resume_receive(socket, state)
    end
  end

  defp resume_receive(socket, state) do
    if state.awaiting_manager? or manager_event_pending?(state) do
      {:noreply, {socket, state}}
    else
      case start_next_receive(state) do
        {next, true} -> {:noreply, {socket, next}}
        {next, false} -> {:noreply, {socket, next}}
      end
    end
  end

  defp stop_link(socket, state, reason) do
    if is_reference(state.session_event_timer), do: Process.cancel_timer(state.session_event_timer)
    Manager.link_closed(state.manager, state.session, reason)
    {:stop, reason, {socket, state}}
  end

  defp manager_event_pending?(state),
    do: not is_nil(state.session_event_ref) or not :queue.is_empty(state.session_event_queue)

  defp can_start_receive?(state) do
    is_nil(state.receive_ref) and not state.awaiting_manager? and not manager_event_pending?(state)
  end

  defp manager_event_timeout_ms(state),
    do: state.config |> then(&timeout(&1, :request_ms, 15_000)) |> max(1)

  defp max_frame(config), do: config |> section(:s2s) |> section(:budgets) |> value(:max_frame_bytes, 1_048_576)

  defp max_pending_frames(config),
    do: config |> section(:s2s) |> section(:budgets) |> value(:max_pending_frames, 65_536)

  defp per_link_queue_bytes(config),
    do: config |> section(:s2s) |> section(:budgets) |> value(:per_link_queue_bytes, 16 * 1_048_576)

  defp max_inbound_queue_bytes(config),
    do: config |> section(:s2s) |> section(:budgets) |> value(:max_inbound_queue_bytes, 2 * 1_048_576)

  defp timeout(config, key, default), do: config |> section(:s2s) |> section(:timeouts) |> value(key, default)

  defp section(config, key) when is_map(config), do: Map.get(config, key, Map.get(config, Atom.to_string(key), %{}))
  defp section(config, key) when is_list(config), do: Keyword.get(config, key, [])
  defp section(_config, _key), do: []

  defp value(section, key, default) when is_map(section),
    do: Map.get(section, key, Map.get(section, Atom.to_string(key), default))

  defp value(section, key, default) when is_list(section), do: Keyword.get(section, key, default)
  defp value(_section, _key, default), do: default

  defp start_receive_worker(state, session, data) do
    owner = self()
    ref = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        result = Session.receive_data(session, data)
        buffer_bytes = receive_buffer_bytes(session)
        send(owner, {:s2s_receive_result, ref, result, buffer_bytes})
      end)

    %{
      state
      | receive_pid: worker,
        receive_ref: ref,
        receive_monitor: monitor,
        receive_in_flight_bytes: byte_size(data)
    }
  end

  defp enqueue_receive_data(state, data) do
    bytes = byte_size(data)

    capacity_available? =
      state.receive_queue_bytes + state.receive_in_flight_bytes + state.receive_buffer_bytes + bytes <=
        state.max_receive_queue_bytes

    if capacity_available? do
      {:ok,
       %{
         state
         | receive_queue: :queue.in(data, state.receive_queue),
           receive_queue_bytes: state.receive_queue_bytes + bytes
       }}
    else
      {:error, :receive_queue_capacity}
    end
  end

  defp start_next_receive(%{receive_queue: queue} = state) do
    case :queue.out(queue) do
      {{:value, data}, rest} ->
        next = %{state | receive_queue: rest, receive_queue_bytes: state.receive_queue_bytes - byte_size(data)}
        {start_receive_worker(next, state.session, data), true}

      {:empty, _} ->
        {state, false}
    end
  end

  defp clear_receive_worker(state),
    do: %{state | receive_pid: nil, receive_ref: nil, receive_monitor: nil, receive_in_flight_bytes: 0}

  defp receive_buffer_bytes(session) do
    Session.state(session).input_buffer_bytes
  catch
    :exit, _reason -> 0
  end

  defp stop_receive_worker(%{receive_pid: pid}) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  defp stop_receive_worker(_state), do: :ok

  defp send_admission_close(socket, reason) do
    frame = %{
      "t" => "close",
      "n" => 1,
      "code" => admission_close_code(reason),
      "reason" => admission_close_reason(reason)
    }

    with {:ok, wire} <- Protocol.encode(frame) do
      _ = ThousandIsland.Socket.send(socket, wire)
    else
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
    _kind, _reason -> :ok
  end

  defp admission_close_code(reason)
       when reason in [:peer_certificate_not_pinned, :missing_peer_certificate, :invalid_peer_socket],
       do: "AUTH"

  defp admission_close_code(reason) when reason in [:duplicate_edge, :unconfigured_neighbor], do: "TOPOLOGY"
  defp admission_close_code(:edge_disabled), do: "OPERATOR"
  defp admission_close_code(_reason), do: "INTERNAL"

  defp admission_close_reason(reason)
       when reason in [:peer_certificate_not_pinned, :missing_peer_certificate, :invalid_peer_socket],
       do: "peer certificate was not accepted"

  defp admission_close_reason(reason) when reason in [:duplicate_edge, :unconfigured_neighbor],
    do: "peer edge is not available"

  defp admission_close_reason(:edge_disabled), do: "peer edge is disabled"
  defp admission_close_reason(_reason), do: "peer admission was rejected"
end
