defmodule ElixIRCd.Observability do
  @moduledoc "Operational events and the bounded Prometheus metric catalog."

  import Telemetry.Metrics

  alias ElixIRCd.Utils.Mnesia

  @reporter :elixircd_prometheus
  @deferred_key {__MODULE__, :deferred}

  @doc "Emits a small, content-free event. Call after a transaction commits."
  @spec emit([atom()], map(), map()) :: :ok
  def emit(name, measurements \\ %{count: 1}, metadata \\ %{}) do
    :telemetry.execute([:elixircd | name], measurements, metadata)
  end

  @doc "Buffers an event until the enclosing observed Mnesia transaction commits."
  @spec defer([atom()], map(), map()) :: :ok
  def defer(name, measurements \\ %{count: 1}, metadata \\ %{}) do
    case Process.get(@deferred_key) do
      events when is_list(events) -> Process.put(@deferred_key, [{name, measurements, metadata} | events])
      nil -> if Memento.Transaction.inside?(), do: :ok, else: emit(name, measurements, metadata)
    end

    :ok
  end

  @doc "Runs a transaction, discarding prior attempts' events on retries or aborts."
  @spec transaction((-> result)) :: result when result: var
  def transaction(fun) do
    started = System.monotonic_time()

    try do
      result =
        Memento.transaction!(fn ->
          Process.put(@deferred_key, [])
          fun.()
        end)

      @deferred_key
      |> Process.get([])
      |> Enum.reverse()
      |> Enum.each(fn {name, measurements, metadata} -> emit(name, measurements, metadata) end)

      emit([:database, :transaction], %{count: 1, duration: System.monotonic_time() - started}, %{result: :success})
      result
    catch
      kind, reason ->
        emit([:database, :transaction], %{count: 1, duration: System.monotonic_time() - started}, %{result: :failure})
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      Process.delete(@deferred_key)
    end
  end

  @doc "Prometheus metrics derived from application and VM events."
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      counter("elixircd.connection.accepted.total",
        event_name: [:elixircd, :connection, :accepted],
        tags: [:transport]
      ),
      counter("elixircd.connection.rejected.total",
        event_name: [:elixircd, :connection, :rejected],
        tags: [:transport, :reason]
      ),
      counter("elixircd.connection.closed.total",
        event_name: [:elixircd, :connection, :closed],
        tags: [:transport, :reason]
      ),
      distribution("elixircd.connection.duration.seconds",
        event_name: [:elixircd, :connection, :closed],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:transport],
        reporter_options: [buckets: [1, 10, 60, 300, 900, 3600, 14_400]]
      ),
      counter("elixircd.command.total", event_name: [:elixircd, :command, :stop], tags: [:command, :result]),
      distribution("elixircd.command.duration.seconds",
        event_name: [:elixircd, :command, :stop],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:command],
        reporter_options: [buckets: [0.001, 0.005, 0.02, 0.1, 0.5, 2, 10]]
      ),
      counter("elixircd.protocol.rejected.total",
        event_name: [:elixircd, :protocol, :rejected],
        tags: [:reason]
      ),
      counter("elixircd.rate_limit.total", event_name: [:elixircd, :rate_limit], tags: [:scope, :reason]),
      counter("elixircd.authentication.total",
        event_name: [:elixircd, :authentication],
        tags: [:method, :result]
      ),
      counter("elixircd.handshake.total", event_name: [:elixircd, :handshake], tags: [:result, :transport]),
      distribution("elixircd.handshake.duration.seconds",
        event_name: [:elixircd, :handshake],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:transport],
        reporter_options: [buckets: [0.01, 0.1, 0.5, 1, 5, 10, 30]]
      ),
      counter("elixircd.lookup.total", event_name: [:elixircd, :lookup], tags: [:kind, :result]),
      distribution("elixircd.lookup.duration.seconds",
        event_name: [:elixircd, :lookup],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:kind],
        reporter_options: [buckets: [0.01, 0.1, 0.5, 1, 5, 10]]
      ),
      counter("elixircd.security.total", event_name: [:elixircd, :security], tags: [:action, :result]),
      counter("elixircd.service.total", event_name: [:elixircd, :service], tags: [:service, :command, :result]),
      counter("elixircd.message.total", event_name: [:elixircd, :message], tags: [:kind]),
      counter("elixircd.history.operations.total", event_name: [:elixircd, :history], tags: [:operation]),
      counter("elixircd.database.transactions.total",
        event_name: [:elixircd, :database, :transaction],
        tags: [:result]
      ),
      distribution("elixircd.database.transaction.duration.seconds",
        event_name: [:elixircd, :database, :transaction],
        measurement: :duration,
        unit: {:native, :second},
        reporter_options: [buckets: [0.001, 0.01, 0.1, 1, 5, 10]]
      ),
      sum("elixircd.history.rows.total", event_name: [:elixircd, :history], measurement: :rows, tags: [:operation]),
      distribution("elixircd.history.query.duration.seconds",
        event_name: [:elixircd, :history],
        measurement: :duration,
        unit: {:native, :second},
        keep: &query_history?/1,
        reporter_options: [buckets: [0.001, 0.01, 0.1, 1, 5]]
      ),
      sum("elixircd.message.recipients.total",
        event_name: [:elixircd, :message],
        measurement: :recipients,
        tags: [:kind]
      ),
      sum("elixircd.transport.received.bytes.total",
        event_name: [:elixircd, :transport, :received],
        measurement: :bytes,
        tags: [:transport]
      ),
      sum("elixircd.transport.sent.bytes.total",
        event_name: [:elixircd, :transport, :sent],
        measurement: :bytes,
        tags: [:transport]
      ),
      sum("elixircd.transport.queued.bytes.total",
        event_name: [:elixircd, :transport, :queued],
        measurement: :bytes,
        tags: [:transport]
      ),
      counter("elixircd.job.total", event_name: [:elixircd, :job], tags: [:type, :result]),
      distribution("elixircd.job.poll.duration.seconds",
        event_name: [:elixircd, :job, :poll],
        measurement: :duration,
        unit: {:native, :second},
        reporter_options: [buckets: [0.001, 0.01, 0.1, 1, 5]]
      ),
      distribution("elixircd.job.duration.seconds",
        event_name: [:elixircd, :job],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:type],
        keep: &(&1.result in [:success, :failure, :crashed]),
        reporter_options: [buckets: [0.01, 0.1, 1, 5, 30, 120, 600]]
      ),
      counter("elixircd.email.total", event_name: [:elixircd, :email], tags: [:purpose, :result]),
      distribution("elixircd.email.duration.seconds",
        event_name: [:elixircd, :email],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:purpose],
        reporter_options: [buckets: [0.01, 0.1, 1, 5, 30]]
      ),
      counter("elixircd.config.reload.total", event_name: [:elixircd, :config, :reload], tags: [:result]),
      last_value("elixircd.ready", event_name: [:elixircd, :sample], measurement: :ready),
      last_value("elixircd.sample.timestamp.seconds", event_name: [:elixircd, :sample], measurement: :timestamp),
      last_value("elixircd.vm.memory.bytes", event_name: [:elixircd, :sample], measurement: :memory_bytes, unit: :byte),
      last_value("elixircd.vm.processes", event_name: [:elixircd, :sample], measurement: :processes),
      last_value("elixircd.vm.run_queue", event_name: [:elixircd, :sample], measurement: :run_queue),
      last_value("elixircd.vm.ets.bytes", event_name: [:elixircd, :sample], measurement: :ets_bytes, unit: :byte),
      last_value("elixircd.vm.atoms", event_name: [:elixircd, :sample], measurement: :atoms),
      last_value("elixircd.vm.ports", event_name: [:elixircd, :sample], measurement: :ports),
      last_value("elixircd.data.available.bytes",
        event_name: [:elixircd, :sample],
        measurement: :disk_available_bytes,
        unit: :byte
      ),
      last_value("elixircd.data.capacity.bytes",
        event_name: [:elixircd, :sample],
        measurement: :disk_capacity_bytes,
        unit: :byte
      ),
      last_value("elixircd.table.rows", event_name: [:elixircd, :table, :sample], measurement: :rows, tags: [:table]),
      last_value("elixircd.jobs.queued", event_name: [:elixircd, :jobs, :sample], measurement: :queued),
      last_value("elixircd.jobs.processing", event_name: [:elixircd, :jobs, :sample], measurement: :processing),
      last_value("elixircd.jobs.failed", event_name: [:elixircd, :jobs, :sample], measurement: :failed),
      last_value("elixircd.jobs.oldest_queued.age.seconds",
        event_name: [:elixircd, :jobs, :sample],
        measurement: :oldest_age,
        unit: :second
      )
    ]
  end

  @doc "Scrapes the in-process reporter."
  @spec scrape() :: String.t()
  def scrape, do: TelemetryMetricsPrometheus.Core.scrape(@reporter)

  @doc "Returns a safe readiness result without performing full-table scans."
  @spec readiness() :: :ok | {:error, atom()}
  def readiness do
    cond do
      :mnesia.system_info(:is_running) != :yes -> {:error, :database}
      not tables_ready?() -> {:error, :tables}
      not process_ready?(ElixIRCd.Server.RateLimiter) -> {:error, :rate_limiter}
      not process_ready?(ElixIRCd.Server.NickEnforcement) -> {:error, :nick_enforcement}
      not process_ready?(ElixIRCd.JobQueue) -> {:error, :jobs}
      not listeners_ready?() -> {:error, :listeners}
      true -> :ok
    end
  catch
    :exit, _ -> {:error, :database}
  end

  @doc "Resolves the private listener address from validated config or a strict Docker override."
  @spec listener_options() :: keyword()
  def listener_options do
    config = Application.fetch_env!(:elixircd, :observability)

    ip =
      case System.get_env("ELIXIRCD_OBSERVABILITY_BIND") do
        nil ->
          config[:bind_ip]

        value ->
          case :inet.parse_strict_address(String.to_charlist(value)) do
            {:ok, address} -> address
            {:error, _} -> raise ArgumentError, "invalid ELIXIRCD_OBSERVABILITY_BIND"
          end
      end

    [ip: ip, port: config[:port], plug: ElixIRCd.Observability.Plug, scheme: :http, startup_log: false]
  end

  @doc "Reporter child spec, started synchronously before application listeners."
  @spec reporter_child_spec() :: Supervisor.child_spec()
  def reporter_child_spec do
    Supervisor.child_spec(
      {TelemetryMetricsPrometheus.Core, name: @reporter, metrics: metrics(), start_async: false},
      id: @reporter
    )
  end

  defp process_ready?(name), do: is_pid(Process.whereis(name))

  defp query_history?(%{operation: :query}), do: true
  defp query_history?(_metadata), do: false

  defp tables_ready? do
    Enum.all?(Mnesia.all_tables(), fn table ->
      :mnesia.table_info(table, :where_to_read) != :nowhere
    end)
  end

  defp listeners_ready? do
    expected = length(Application.fetch_env!(:elixircd, :listeners))

    case Process.whereis(ElixIRCd.Server.Listeners) do
      nil ->
        false

      _pid ->
        children = Supervisor.which_children(ElixIRCd.Server.Listeners)
        length(children) == expected and Enum.all?(children, fn {_id, pid, _type, _modules} -> is_pid(pid) end)
    end
  end
end
