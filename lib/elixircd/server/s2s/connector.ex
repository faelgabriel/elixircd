defmodule ElixIRCd.Server.S2S.Connector do
  @moduledoc "One supervised outbound ENP/1 connector to the configured parent."

  use GenServer

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.Session
  alias ElixIRCd.Server.S2S.TLS

  @max_pending_session_events 8

  @doc "Starts one temporary outbound connector for a configured parent edge."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc "Returns the temporary child specification for one outbound connector."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    %{
      id: {__MODULE__, Keyword.fetch!(options, :peer_sid)},
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary,
      shutdown: 15_000,
      type: :worker
    }
  end

  @impl true
  def init(options) do
    Process.send_after(self(), :connect, 0)

    {:ok,
     %{
       manager: Keyword.fetch!(options, :manager),
       config: Keyword.fetch!(options, :config),
       peer_sid: Keyword.fetch!(options, :peer_sid),
       generation: Keyword.get(options, :generation, Identity.nonce()),
       socket: nil,
       session: nil,
       monitor: nil,
       receive_pid: nil,
       receive_ref: nil,
       receive_monitor: nil,
       receive_queue: :queue.new(),
       receive_queue_bytes: 0,
       receive_in_flight_bytes: 0,
       receive_buffer_bytes: 0,
       max_receive_queue_bytes: max_inbound_queue_bytes(Keyword.fetch!(options, :config)),
       session_event_queue: :queue.new(),
       session_event_ref: nil,
       session_event_timer: nil,
       awaiting_manager?: false,
       manager_event_ack_before_receive?: false,
       peer_info: nil,
       peer_close_code: nil,
       quit?: false
     }}
  end

  @impl true
  def handle_call({:s2s_send, wire}, _from, %{socket: socket} = state) when is_binary(wire) do
    case :ssl.send(socket, wire) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:s2s_send, _wire}, _from, state), do: {:reply, {:error, :socket_not_ready}, state}

  @impl true
  def handle_info(:connect, %{socket: nil} = state) do
    s2s = section(state.config, :s2s)
    parent = section(s2s, :parent_connection)

    case connect(parent, TLS.client_options(s2s, parent)) do
      {:ok, socket} ->
        with {:ok, peer_info} <- TLS.peer_info(:ssl, socket),
             :ok <- Manager.admit_outbound(state.manager, state.peer_sid, peer_info),
             local_hello <- Manager.local_hello(state.manager),
             {:ok, session} <-
               Session.start_link(
                 local_hello: local_hello,
                 generation: state.generation,
                 hello_timeout_ms: timeout(state.config, :tls_hello_ms, 15_000),
                 incomplete_frame_ms: timeout(state.config, :incomplete_frame_ms, 15_000),
                 max_body: max_frame(state.config),
                 max_outbound_frames: max_pending_frames(state.config),
                 max_outbound_bytes: per_link_queue_bytes(state.config),
                 send_fun: send_fun(self()),
                 notify: self()
               ),
             {:ok, _} <-
               Manager.register_session(state.manager, session, %{
                 direction: :outgoing,
                 peer_sid: state.peer_sid,
                 peer_name: value(parent, :sni, value(parent, :address, "")),
                 peer_info: peer_info,
                 owner: self(),
                 generation: state.generation,
                 local_hello: local_hello
               }),
             :ok <- :ssl.setopts(socket, active: :once) do
          Process.unlink(session)
          Session.set_admission_fun(session, fn frame -> Manager.admit_hello(state.manager, session, frame) end)
          monitor = Process.monitor(session)
          Session.tls_established(session)
          {:noreply, %{state | socket: socket, session: session, monitor: monitor, peer_info: peer_info}}
        else
          {:error, reason} ->
            close_socket(socket)
            report_down(state, reason)

          _ ->
            close_socket(socket)
            report_down(state, :session_start_failed)
        end

      {:error, reason} ->
        report_down(state, reason)
    end
  end

  def handle_info({:ssl, socket, data}, %{socket: socket} = state) when is_binary(data) do
    cond do
      byte_size(data) > state.max_receive_queue_bytes ->
        stop_link(state, :receive_chunk_overrun)

      can_start_receive?(state) ->
        {:noreply, start_receive_worker(state, state.session, data)}

      true ->
        case enqueue_receive_data(state, data) do
          {:ok, next} -> {:noreply, next}
          {:error, _reason} -> stop_link(state, :receive_queue_overrun)
        end
    end
  end

  def handle_info(
        {:s2s_receive_result, ref, result, buffer_bytes},
        %{receive_ref: ref, receive_monitor: monitor} = state
      ) do
    Process.demonitor(monitor, [:flush])
    state = clear_receive_worker(%{state | receive_buffer_bytes: buffer_bytes})

    case result do
      :ok ->
        resume_receive(%{state | awaiting_manager?: false, manager_event_ack_before_receive?: false})

      :manager_pending ->
        state = %{state | awaiting_manager?: true}

        if state.manager_event_ack_before_receive? and not manager_event_pending?(state) do
          next = %{state | awaiting_manager?: false, manager_event_ack_before_receive?: false}
          {:noreply, start_receive_worker(next, next.session, <<>>)}
        else
          {:noreply, state}
        end

      {:error, reason} ->
        stop_link(state, {:receive_error, reason})
    end
  end

  def handle_info(
        {:s2s_manager_event_ack, ref, status},
        %{session_event_ref: ref} = state
      ) do
    case status do
      :ok -> complete_manager_event(state)
      :stale -> stop_link(state, :stale_session_generation)
      :closing -> stop_link(state, :manager_shutting_down)
      _ -> stop_link(state, :invalid_manager_ack)
    end
  end

  def handle_info({:s2s_manager_event_ack, _ref, _status}, state), do: {:noreply, state}

  def handle_info(
        {:s2s_manager_event_timeout, ref},
        %{session_event_ref: ref} = state
      ),
      do: stop_link(state, :manager_event_timeout)

  def handle_info({:s2s_manager_event_timeout, _ref}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, monitor, :process, _worker, reason},
        %{receive_monitor: monitor} = state
      ) do
    stop_link(state, {:receive_worker_down, reason})
  end

  def handle_info({:ssl_closed, socket}, %{socket: socket} = state), do: stop_link(state, :closed)
  def handle_info({:ssl_error, socket, reason}, %{socket: socket} = state), do: stop_link(state, {:ssl_error, reason})

  def handle_info({:s2s_session, session, generation, {:close, code}}, %{session: session} = state) do
    queue_session_event(%{state | peer_close_code: code}, generation, {:close, code})
  end

  def handle_info({:s2s_session, session, generation, event}, %{session: session} = state) do
    queue_session_event(state, generation, event)
  end

  def handle_info({:DOWN, monitor, :process, session, reason}, %{monitor: monitor, session: session} = state) do
    reason =
      if state.peer_close_code, do: {:session_down, {:peer_close, state.peer_close_code}}, else: {:session_down, reason}

    stop_link(state, reason)
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    stop_receive_worker(state)
    if is_reference(state.session_event_timer), do: Process.cancel_timer(state.session_event_timer)
    if state.session, do: Manager.link_closed(state.manager, state.session, reason)
    close_socket(state.socket)
    :ok
  end

  defp connect(parent, options) do
    address = value(parent, :address, "")
    port = value(parent, :port, 0)
    :ssl.connect(to_charlist(address), port, options, 10_000)
  end

  defp stop_link(state, reason) do
    if state.session, do: Manager.link_closed(state.manager, state.session, reason)
    {:stop, reason, state}
  end

  defp report_down(state, reason) do
    send(state.manager, {:s2s_connector_down, self(), reason})
    {:stop, {:connect_failed, reason}, state}
  end

  defp close_socket(nil), do: :ok
  defp close_socket(socket), do: :ssl.close(socket)

  defp send_fun(connector),
    do: fn wire ->
      try do
        GenServer.call(connector, {:s2s_send, wire}, 15_000)
      catch
        :exit, reason -> {:error, {:transport, reason}}
      end
    end

  defp queue_session_event(state, generation, event) do
    if :queue.len(state.session_event_queue) >= @max_pending_session_events do
      stop_link(state, :manager_event_queue_overrun)
    else
      queue = :queue.in({generation, event}, state.session_event_queue)
      {:noreply, dispatch_manager_event(%{state | session_event_queue: queue})}
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

  defp complete_manager_event(state) do
    if is_reference(state.session_event_timer), do: Process.cancel_timer(state.session_event_timer)

    state = %{
      state
      | session_event_ref: nil,
        session_event_timer: nil
    }

    state = dispatch_manager_event(state)

    cond do
      manager_event_pending?(state) ->
        {:noreply, state}

      is_pid(state.receive_pid) ->
        {:noreply, %{state | manager_event_ack_before_receive?: true}}

      state.awaiting_manager? ->
        next = %{state | awaiting_manager?: false, manager_event_ack_before_receive?: false}
        {:noreply, start_receive_worker(next, next.session, <<>>)}

      true ->
        resume_receive(state)
    end
  end

  defp manager_event_pending?(state),
    do: not is_nil(state.session_event_ref) or not :queue.is_empty(state.session_event_queue)

  defp can_start_receive?(state) do
    is_nil(state.receive_ref) and not state.awaiting_manager? and not manager_event_pending?(state)
  end

  defp resume_receive(state) do
    if state.awaiting_manager? or manager_event_pending?(state) do
      {:noreply, state}
    else
      case start_next_receive(state) do
        {next, true} ->
          {:noreply, next}

        {next, false} ->
          case :ssl.setopts(next.socket, active: :once) do
            :ok -> {:noreply, next}
            {:error, reason} -> stop_link(next, {:setopts, reason})
          end
      end
    end
  end

  defp manager_event_timeout_ms(state),
    do: state.config |> then(&timeout(&1, :request_ms, 15_000)) |> max(1)

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

  defp clear_receive_worker(state),
    do: %{state | receive_pid: nil, receive_ref: nil, receive_monitor: nil, receive_in_flight_bytes: 0}

  defp enqueue_receive_data(state, data) when is_binary(data) do
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

  defp stop_receive_worker(%{receive_pid: pid}) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  defp stop_receive_worker(_state), do: :ok

  defp receive_buffer_bytes(session) do
    Session.state(session).input_buffer_bytes
  catch
    :exit, _reason -> 0
  end

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
end
