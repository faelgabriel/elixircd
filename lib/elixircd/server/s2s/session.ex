defmodule ElixIRCd.Server.S2S.Session do
  @moduledoc """
  One ENP/1 physical-link state machine.

  The session owns framing state, direction-local sequence numbers and the
  link generation. Socket I/O is injected through a small send callback so
  protocol transitions remain testable without a distributed Erlang node.
  """

  use GenServer

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Protocol
  alias ElixIRCd.Server.S2S.Schema

  @absolute_limit 1_048_576
  @receive_timeout 15_000

  @type phase :: :tls | :hello | :syncing | :active | :closing

  @doc "Starts one generation-fenced session."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  @doc "Notifies a session that mutual TLS has completed."
  @spec tls_established(pid()) :: :ok
  def tls_established(pid), do: GenServer.cast(pid, :tls_established)

  @doc "Feeds one bounded TLS chunk and waits for parsing before the socket is re-armed."
  @spec receive_data(pid(), binary()) :: :ok | :manager_pending | {:error, term()}
  def receive_data(pid, data) when is_binary(data) do
    GenServer.call(pid, {:data, data}, @receive_timeout)
  catch
    :exit, reason -> {:error, reason}
  end

  def receive_data(_pid, _data), do: {:error, :invalid_transport_chunk}

  @doc "Queues one semantic frame; the session assigns its next local n."
  @spec send_frame(pid(), map()) :: :ok | {:error, term()}
  def send_frame(pid, frame), do: GenServer.call(pid, {:send_frame, frame})

  @doc "Enqueues one semantic frame in the bounded per-link output queue."
  @spec enqueue_frame(pid(), map()) :: :ok | {:error, term()}
  def enqueue_frame(pid, frame) when is_pid(pid) and is_map(frame) do
    GenServer.call(pid, {:enqueue_frame, frame}, @receive_timeout)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Sends an ENP heartbeat and tracks its bounded response timeout."
  @spec ping(pid(), Identity.id(), pos_integer()) :: :ok | {:error, term()}
  def ping(pid, token \\ Identity.nonce(), timeout_ms \\ 60_000),
    do: GenServer.call(pid, {:ping, token, timeout_ms})

  @doc "Marks one snapshot lifecycle fact."
  @spec mark_sync(pid(), :sent | :applied | :acknowledged) :: :ok
  def mark_sync(pid, fact), do: GenServer.cast(pid, {:sync, fact})

  @doc "Installs the manager callback after the session process has an identity."
  @spec set_admission_fun(pid(), (map() -> :ok | {:error, term()})) :: :ok
  def set_admission_fun(pid, fun) when is_function(fun, 1), do: GenServer.cast(pid, {:admission_fun, fun})

  @doc "Requests an explicit graceful close."
  @spec close(pid(), String.t(), String.t()) :: :ok
  def close(pid, code, reason), do: GenServer.cast(pid, {:close, code, reason})

  @doc "Returns the observable session state for diagnostics/tests."
  @spec state(pid(), timeout()) :: map()
  def state(pid, timeout \\ 5_000), do: GenServer.call(pid, :state, timeout)

  @impl true
  def init(options) do
    local_hello = Keyword.fetch!(options, :local_hello)
    generation = Keyword.get(options, :generation, Identity.nonce())
    timeout = Keyword.get(options, :hello_timeout_ms, 15_000)

    with :ok <- Schema.validate_frame(local_hello) do
      state = %{
        phase: :tls,
        generation: generation,
        local_hello: local_hello,
        remote_hello: nil,
        buffer: <<>>,
        awaiting_manager?: false,
        send_n: 1,
        recv_n: 1,
        sync_sent?: false,
        sync_applied?: false,
        sync_acknowledged?: false,
        outstanding_pings: %{},
        send_fun: Keyword.get(options, :send_fun),
        notify: Keyword.get(options, :notify, self()),
        admission_fun: Keyword.get(options, :admission_fun),
        profile_hash: Keyword.get(options, :profile_hash, local_hello["profile_hash"]),
        hello_timeout_ms: timeout,
        incomplete_frame_ms: Keyword.get(options, :incomplete_frame_ms, 15_000),
        max_body: normalize_body_limit(Keyword.get(options, :max_body, @absolute_limit)),
        clock_fun: Keyword.get(options, :clock_fun, fn -> System.system_time(:millisecond) end),
        hello_timer: nil,
        hello_warning_timer: nil,
        incomplete_frame_timer: nil,
        incomplete_frame_token: nil,
        hello_warning_ms: Keyword.get(options, :hello_warning_ms, 5_000),
        close_sent?: false,
        outbound: :queue.new(),
        outbound_bytes: 0,
        outbound_draining?: false,
        max_outbound_frames: Keyword.get(options, :max_outbound_frames, 65_536),
        max_outbound_bytes: Keyword.get(options, :max_outbound_bytes, 16 * 1_048_576)
      }

      if Keyword.get(options, :tls_established, false),
        do: {:ok, state, {:continue, :send_hello}},
        else: {:ok, state}
    else
      {:error, _} = error -> {:stop, {:invalid_local_hello, error}}
    end
  end

  @impl true
  def handle_continue(:send_hello, state), do: {:noreply, send_hello(state)}

  @impl true
  def handle_cast(:tls_established, %{phase: :tls} = state) do
    {:noreply, send_hello(state)}
  end

  def handle_cast(:tls_established, state), do: {:noreply, state}

  def handle_cast({:sync, fact}, state) when fact in [:sent, :applied, :acknowledged] do
    {:noreply, maybe_active(put_sync_fact(state, fact))}
  end

  def handle_cast({:admission_fun, fun}, state) when is_function(fun, 1),
    do: {:noreply, %{state | admission_fun: fun}}

  def handle_cast({:close, code, reason}, state) do
    {:stop, :normal, send_close(state, code, reason)}
  end

  @impl true
  def handle_call({:enqueue_frame, frame}, _from, %{phase: phase} = state) when phase in [:syncing, :active] do
    case queue_post_hello(state, frame) do
      {:ok, next} -> {:reply, :ok, schedule_drain(next)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:enqueue_frame, _frame}, _from, state),
    do: {:reply, {:error, :session_not_ready}, state}

  def handle_call({:send_frame, frame}, from, state),
    do: handle_call({:enqueue_frame, frame}, from, state)

  def handle_call({:ping, token, timeout_ms}, _from, %{phase: phase} = state)
      when phase in [:syncing, :active] and is_integer(timeout_ms) and timeout_ms > 0 do
    if Identity.valid_id?(token) and not Map.has_key?(state.outstanding_pings, token) do
      case queue_post_hello(state, %{"t" => "ping", "token" => token}) do
        {:ok, next} ->
          timer = Process.send_after(self(), {:ping_timeout, token}, timeout_ms)
          pings = Map.put(next.outstanding_pings, token, timer)
          {:reply, :ok, schedule_drain(%{next | outstanding_pings: pings})}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :invalid_ping_token}, state}
    end
  end

  def handle_call({:ping, _token, _timeout_ms}, _from, state), do: {:reply, {:error, :session_not_ready}, state}

  def handle_call(:state, _from, state),
    do:
      {:reply,
       Map.take(state, [
         :phase,
         :generation,
         :remote_hello,
         :send_n,
         :recv_n,
         :sync_sent?,
         :sync_applied?,
         :sync_acknowledged?
       ])
       |> Map.merge(%{
         outbound_frames: :queue.len(state.outbound),
         outbound_bytes: state.outbound_bytes,
         max_outbound_frames: state.max_outbound_frames,
         max_outbound_bytes: state.max_outbound_bytes,
         input_buffer_bytes: byte_size(state.buffer)
       }), state}

  def handle_call({:data, data}, _from, state) when is_binary(data) do
    cond do
      state.awaiting_manager? and data != <<>> ->
        {:reply, {:error, :manager_ack_required}, state}

      true ->
        case ingest_data(%{state | awaiting_manager?: false}, data) do
          {:ok, next, result} ->
            {:reply, result, next}

          {:error, reason, next} ->
            {:stop, {:protocol, reason}, {:error, reason}, send_close(next, close_code(reason), safe_reason(reason))}
        end
    end
  end

  def handle_call({:data, _data}, _from, state), do: {:reply, {:error, :invalid_transport_chunk}, state}

  defp ingest_data(state, data) do
    ingest_frames(state, data)
  end

  defp ingest_frames(state, data) do
    case Protocol.feed(state.buffer, data,
           limit: input_limit(state),
           include_bodies: true,
           max_frames: 1
         ) do
      {:ok, [], buffer} ->
        {:ok, refresh_incomplete_frame_timer(%{state | buffer: buffer}), :ok}

      {:ok, [{frame, body}], buffer} ->
        case consume_frame(frame, body, %{state | buffer: buffer}) do
          {:ok, next, :manager_pending} ->
            {:ok, %{next | awaiting_manager?: true}, :manager_pending}

          {:ok, next, :continue} ->
            ingest_frames(next, <<>>)

          {:error, reason, next} ->
            {:error, reason, next}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp input_limit(%{phase: phase, max_body: max_body}) when phase in [:tls, :hello],
    do: min(max_body, Protocol.body_limit("hello"))

  defp input_limit(%{max_body: max_body}), do: max_body

  @impl true
  def handle_info({:hello_timeout, generation}, %{generation: generation, phase: phase} = state)
      when phase in [:tls, :hello] do
    {:stop, {:protocol, :hello_timeout}, send_close(state, "TIMEOUT", "hello timeout")}
  end

  def handle_info({:hello_timeout, _generation}, state), do: {:noreply, state}

  def handle_info(
        {:incomplete_frame_timeout, generation, token},
        %{generation: generation, buffer: buffer, incomplete_frame_token: token} = state
      )
      when buffer != <<>> do
    {:stop, {:protocol, :incomplete_frame_timeout}, send_close(state, "TIMEOUT", "incomplete frame timeout")}
  end

  def handle_info({:incomplete_frame_timeout, _generation, _token}, state), do: {:noreply, state}

  def handle_info({:hello_warning, generation}, %{generation: generation, phase: phase} = state)
      when phase in [:tls, :hello] do
    notify(state, {:hello_warning, generation})
    {:noreply, state}
  end

  def handle_info({:hello_warning, _generation}, state), do: {:noreply, state}

  def handle_info({:ping_timeout, token}, state) do
    if Map.has_key?(state.outstanding_pings, token),
      do: {:stop, {:protocol, :heartbeat_timeout}, send_close(state, "TIMEOUT", "heartbeat timeout")},
      else: {:noreply, state}
  end

  def handle_info(:drain_outbound, state) do
    case drain_one(state) do
      {:ok, next} ->
        {:noreply, schedule_drain(next)}

      {:empty, next} ->
        {:noreply, next}

      {:error, reason, next} ->
        notify(next, {:send_error, reason})
        {:stop, {:send_error, reason}, %{next | phase: :closing}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.hello_timer)
    cancel_timer(state.hello_warning_timer)
    cancel_timer(state.incomplete_frame_timer)
    Enum.each(state.outstanding_pings, fn {_token, timer} -> cancel_timer(timer) end)
    :ok
  end

  defp send_hello(%{phase: :tls} = state) do
    case emit_wire(state, state.local_hello) do
      {:ok, wire} ->
        case send_wire(state, wire, state.local_hello) do
          :ok ->
            timer = Process.send_after(self(), {:hello_timeout, state.generation}, state.hello_timeout_ms)
            warning_ms = min(state.hello_warning_ms, max(state.hello_timeout_ms - 1, 1))
            warning_timer = Process.send_after(self(), {:hello_warning, state.generation}, warning_ms)
            %{state | phase: :hello, hello_timer: timer, hello_warning_timer: warning_timer}

          {:error, reason} ->
            notify(state, {:send_error, reason})
            %{state | phase: :closing}
        end

      {:error, reason} ->
        notify(state, {:send_error, reason})
        %{state | phase: :closing}
    end
  end

  defp send_hello(state), do: state

  defp refresh_incomplete_frame_timer(%{buffer: <<>>, incomplete_frame_timer: timer} = state) do
    cancel_timer(timer)
    %{state | incomplete_frame_timer: nil, incomplete_frame_token: nil}
  end

  defp refresh_incomplete_frame_timer(
         %{buffer: buffer, incomplete_frame_timer: nil, incomplete_frame_token: nil} = state
       )
       when buffer != <<>> do
    token = Identity.nonce()
    timer = Process.send_after(self(), {:incomplete_frame_timeout, state.generation, token}, state.incomplete_frame_ms)
    %{state | incomplete_frame_timer: timer, incomplete_frame_token: token}
  end

  defp refresh_incomplete_frame_timer(state), do: state

  defp consume_frame(%{"t" => "hello"} = frame, _body, %{phase: :hello} = state) do
    case admit_hello(frame, state) do
      :ok ->
        next = %{state | remote_hello: frame, phase: :syncing}
        cancel_timer(state.hello_timer)
        cancel_timer(state.hello_warning_timer)
        notify(next, {:hello, frame})
        {:ok, next, :manager_pending}

      {:error, _} = error ->
        {:error, elem(error, 1), state}
    end
  end

  defp consume_frame(%{"t" => "hello"}, _body, state), do: {:error, :duplicate_hello, state}

  defp consume_frame(%{"t" => "close", "code" => code}, _body, %{phase: phase} = state)
       when phase in [:tls, :hello] do
    notify(state, {:close, code})
    {:error, :peer_close, state}
  end

  defp consume_frame(%{"n" => n} = frame, body, %{phase: phase, recv_n: expected} = state)
       when phase in [:syncing, :active] do
    if n != expected do
      {:error, {:sequence_gap, expected, n}, state}
    else
      next = %{state | recv_n: expected + 1}
      dispatch_frame(frame, body, next)
    end
  end

  defp consume_frame(_frame, _body, state), do: {:error, :frame_before_hello, state}

  defp dispatch_frame(%{"t" => "ping", "token" => token}, _body, state) do
    case queue_post_hello(state, %{"t" => "pong", "token" => token}) do
      {:ok, next} -> {:ok, schedule_drain(next), :continue}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp dispatch_frame(%{"t" => "pong", "token" => token}, _body, state) do
    if Map.has_key?(state.outstanding_pings, token),
      do: {:ok, %{state | outstanding_pings: cancel_ping(state, token)}, :continue},
      else: {:error, :unexpected_pong, state}
  end

  defp dispatch_frame(%{"t" => "close", "code" => code}, _body, state) do
    notify(state, {:close, code})
    {:error, :peer_close, state}
  end

  defp dispatch_frame(frame, body, state) do
    notify(state, {:frame, frame, body, System.monotonic_time(:millisecond)})
    {:ok, maybe_active(state), :manager_pending}
  end

  defp admit_hello(frame, state) do
    with :ok <- Schema.validate_frame(frame),
         true <- frame["protocol"] == state.local_hello["protocol"],
         true <- frame["version"] == state.local_hello["version"],
         true <- frame["network_id"] == state.local_hello["network_id"],
         true <- Identity.secure_equal?(frame["profile_hash"], state.profile_hash),
         true <- abs(state.clock_fun.() - frame["time_ms"]) <= 30_000,
         :ok <- admission(state, frame) do
      :ok
    else
      false -> {:error, :hello_mismatch}
      {:error, _} = error -> error
    end
  end

  defp admission(%{admission_fun: fun}, frame) when is_function(fun, 1) do
    case fun.(frame) do
      :ok -> :ok
      {:error, _} = error -> error
      _ -> {:error, :neighbor_rejected}
    end
  end

  defp admission(_state, _frame), do: :ok

  defp queue_post_hello(state, frame) when is_map(frame) do
    frame = Map.put(frame, "n", state.send_n)

    case emit_wire(state, frame) do
      {:ok, wire} ->
        if outbound_capacity?(state, byte_size(wire)) do
          outbound = :queue.in({wire, frame}, state.outbound)

          {:ok,
           %{
             state
             | outbound: outbound,
               outbound_bytes: state.outbound_bytes + byte_size(wire),
               send_n: state.send_n + 1
           }}
        else
          {:error, :outbound_queue_capacity}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp emit_wire(state, frame) do
    case Protocol.encode(frame) do
      {:ok, <<body_size::unsigned-big-32, _body::binary>> = wire} when body_size <= state.max_body ->
        {:ok, wire}

      {:ok, <<body_size::unsigned-big-32, _body::binary>>} ->
        {:error, {:frame_too_large, body_size, state.max_body}}

      {:error, _} = error ->
        error
    end
  end

  defp normalize_body_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @absolute_limit)
  defp normalize_body_limit(_limit), do: @absolute_limit

  defp send_close(state, code, reason) do
    if state.close_sent? or state.phase == :tls do
      state
    else
      frame = %{"t" => "close", "code" => code, "reason" => reason}

      case queue_post_hello(state, frame) do
        {:ok, next} ->
          next = drain_all(next)
          %{next | close_sent?: true, phase: :closing}

        {:error, _reason} ->
          %{state | close_sent?: true, phase: :closing}
      end
    end
  end

  defp outbound_capacity?(state, bytes) do
    :queue.len(state.outbound) < state.max_outbound_frames and
      state.outbound_bytes + bytes <= state.max_outbound_bytes
  end

  defp schedule_drain(%{outbound_draining?: true} = state), do: state

  defp schedule_drain(%{outbound: outbound} = state) do
    if :queue.is_empty(outbound) do
      %{state | outbound_draining?: false}
    else
      send(self(), :drain_outbound)
      %{state | outbound_draining?: true}
    end
  end

  defp drain_one(%{outbound: outbound} = state) do
    case :queue.out(outbound) do
      {{:value, {wire, frame}}, rest} ->
        case send_wire(state, wire, frame) do
          :ok ->
            {:ok,
             %{
               state
               | outbound: rest,
                 outbound_bytes: state.outbound_bytes - byte_size(wire),
                 outbound_draining?: false
             }}

          {:error, reason} ->
            {:error, reason, %{state | outbound_draining?: false}}
        end

      {:empty, _rest} ->
        {:empty, %{state | outbound_draining?: false}}
    end
  end

  defp drain_all(state) do
    case drain_one(state) do
      {:ok, next} -> drain_all(next)
      {:empty, next} -> next
      {:error, _reason, next} -> next
    end
  end

  defp send_wire(state, wire, frame) do
    case state.send_fun do
      fun when is_function(fun, 1) ->
        try do
          case fun.(wire) do
            :ok -> :ok
            {:error, _reason} = error -> error
            other -> {:error, {:transport, {:unexpected_send_result, other}}}
          end
        rescue
          error -> {:error, {:transport, Exception.message(error)}}
        catch
          kind, reason -> {:error, {:transport, {kind, reason}}}
        end

      _ ->
        notify(state, {:send, frame, wire})
        :ok
    end
  end

  defp put_sync_fact(state, :sent), do: %{state | sync_sent?: true}
  defp put_sync_fact(state, :applied), do: %{state | sync_applied?: true}
  defp put_sync_fact(state, :acknowledged), do: %{state | sync_acknowledged?: true}

  defp maybe_active(%{phase: :syncing, sync_sent?: true, sync_applied?: true, sync_acknowledged?: true} = state) do
    notify(state, :active)
    %{state | phase: :active}
  end

  defp maybe_active(state), do: state

  defp notify(%{notify: pid, generation: generation}, event) when is_pid(pid),
    do: send(pid, {:s2s_session, self(), generation, event})

  defp notify(_state, _event), do: :ok

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp cancel_ping(state, token) do
    case Map.pop(state.outstanding_pings, token) do
      {nil, pings} ->
        pings

      {timer, pings} ->
        Process.cancel_timer(timer)
        pings
    end
  end

  defp close_code({:sequence_gap, _, _}), do: "FRAME"
  defp close_code({:frame_too_large, _, _}), do: "FRAME"
  defp close_code(:partial_frame_too_large), do: "FRAME"
  defp close_code(:frame_too_large), do: "FRAME"
  defp close_code(:duplicate_hello), do: "SCHEMA"
  defp close_code(:frame_before_hello), do: "AUTH"
  defp close_code(:unexpected_pong), do: "FRAME"
  defp close_code(:hello_timeout), do: "TIMEOUT"
  defp close_code(:heartbeat_timeout), do: "TIMEOUT"
  defp close_code(_reason), do: "SCHEMA"

  defp safe_reason({:sequence_gap, expected, received}), do: "sequence #{expected}/#{received}"
  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "protocol error"
end
