defmodule ElixIRCd.ObservabilityTest do
  @moduledoc false

  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias ElixIRCd.Config.Loader
  alias ElixIRCd.Observability
  alias ElixIRCd.Observability.Plug, as: OperationalPlug
  alias ElixIRCd.Observability.Poller
  alias ElixIRCd.Repositories.Jobs
  alias ElixIRCd.Utils.Mnesia

  test "disabling observability omits every monitoring child at startup" do
    original_config = Application.fetch_env!(:elixircd, :observability)
    original_start_time = :persistent_term.get(:app_start_time)

    on_exit(fn ->
      Application.put_env(:elixircd, :observability, original_config)
      :persistent_term.put(:app_start_time, original_start_time)
    end)

    Application.put_env(:elixircd, :observability, Keyword.put(original_config, :enabled, false))
    test_pid = self()

    stub(Mnesia, :setup_mnesia, fn ->
      send(test_pid, :database_initialized)
      :ok
    end)

    stub(Loader, :load!, fn "config/elixircd.exs", :boot ->
      assert_received :database_initialized
      :ok
    end)

    expect(Supervisor, :start_link, fn children, opts ->
      assert children == [
               ElixIRCd.Server.RateLimiter,
               ElixIRCd.Server.NickEnforcement,
               ElixIRCd.Server.Listeners,
               ElixIRCd.JobQueue
             ]

      assert opts[:name] == ElixIRCd
      {:ok, self()}
    end)

    assert {:ok, ^test_pid} = ElixIRCd.start(:normal, [])
  end

  test "operational routes report health and expose Prometheus text" do
    live = OperationalPlug.call(Plug.Test.conn(:get, "/health/live"), [])
    assert live.status == 200
    assert live.resp_body == "ok\n"

    ready = OperationalPlug.call(Plug.Test.conn(:get, "/health/ready"), [])
    assert ready.status == 200

    Observability.emit([:connection, :rejected], %{count: 1}, %{transport: :tcp, reason: :throttled})
    metrics = OperationalPlug.call(Plug.Test.conn(:get, "/metrics"), [])
    assert metrics.status == 200
    assert metrics.resp_body =~ "elixircd_connection_rejected_total"
    assert metrics.resp_body =~ ~s(reason="throttled")

    assert OperationalPlug.call(Plug.Test.conn(:get, "/missing"), []).status == 404
    assert OperationalPlug.call(Plug.Test.conn(:post, "/metrics"), []).status == 404
  end

  test "deferred events are emitted once after commit and discarded on abort" do
    test_pid = self()
    handler = "observability-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:elixircd, :security],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok =
             Observability.transaction(fn ->
               Observability.defer([:security], %{count: 1}, %{action: :oper, result: :success})
               refute_received {%{count: 1}, %{action: :oper}}
               :ok
             end)

    assert_received {%{count: 1}, %{action: :oper, result: :success}}

    assert_raise RuntimeError, fn ->
      Observability.transaction(fn ->
        Observability.defer([:security], %{count: 1}, %{action: :oper, result: :failure})
        raise "rollback"
      end)
    end

    refute_received {%{count: 1}, %{action: :oper, result: :failure}}
  end

  test "external effects run after commit and are discarded on abort" do
    assert :ok =
             Observability.transaction(fn ->
               Observability.defer_effect(fn -> send(self(), :committed_effect) end)
               refute_received :committed_effect
               :ok
             end)

    assert_received :committed_effect

    assert_raise RuntimeError, fn ->
      Observability.transaction(fn ->
        Observability.defer_effect(fn -> send(self(), :aborted_effect) end)
        raise "rollback"
      end)
    end

    refute_received :aborted_effect
  end

  test "nested observed transactions leave effects for the outer commit" do
    assert :ok =
             Observability.transaction(fn ->
               Observability.transaction(fn ->
                 Observability.defer_effect(fn -> send(self(), :nested_effect) end)
               end)

               refute_received :nested_effect
               :ok
             end)

    assert_received :nested_effect

    assert_raise ArgumentError, ~r/observed outer transaction/, fn ->
      Memento.transaction!(fn -> Observability.transaction(fn -> :ok end) end)
    end
  end

  test "a post-commit effect can start another observed transaction" do
    Observability.transaction(fn ->
      Observability.defer_effect(fn ->
        Observability.transaction(fn ->
          Observability.defer_effect(fn -> send(self(), :later_effect) end)
        end)
      end)
    end)

    assert_received :later_effect
  end

  test "a post-commit effect emits telemetry outside the completed transaction" do
    test_pid = self()
    handler = "observability-effect-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:elixircd, :security],
        fn _event, _measurements, metadata, _config -> send(test_pid, {:effect_event, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    Observability.transaction(fn ->
      Observability.defer_effect(fn -> Observability.defer([:security], %{count: 1}, %{source: :effect}) end)
    end)

    assert_received {:effect_event, %{source: :effect}}
  end

  test "a telemetry handler cannot replace effects awaiting delivery after commit" do
    test_pid = self()
    handler = "observability-nested-handler-#{System.unique_integer([:positive])}"
    nested_key = {__MODULE__, :nested_handler}

    :ok =
      :telemetry.attach(
        handler,
        [:elixircd, :database, :transaction],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid and metadata.result == :success and Process.get(nested_key) != true do
            Process.put(nested_key, true)
            Observability.transaction(fn -> :ok end)
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    Observability.transaction(fn ->
      Observability.defer_effect(fn -> send(self(), :outer_effect) end)
    end)

    assert_received :outer_effect
  end

  test "external effects execute immediately without an observed transaction" do
    assert :ok = Observability.defer_effect(fn -> send(self(), :immediate_effect) end)
    assert_received :immediate_effect

    Memento.transaction!(fn -> Observability.defer_effect(fn -> send(self(), :raw_transaction_effect) end) end)
    assert_received :raw_transaction_effect
  end

  test "a failing post-commit effect does not report a database rollback" do
    test_pid = self()
    handler = "observability-postcommit-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:elixircd, :database, :transaction],
        fn _event, _measurements, %{result: result}, _config ->
          if self() == test_pid, do: send(test_pid, {:database_result, result})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert_raise RuntimeError, "post-commit failure", fn ->
      Observability.transaction(fn ->
        Observability.defer_effect(fn -> raise "post-commit failure" end)
        :ok
      end)
    end

    assert_received {:database_result, :success}
    refute_received {:database_result, :failure}
  end

  test "a raw transaction does not publish an uncommitted operational event" do
    test_pid = self()
    handler = "observability-raw-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:elixircd, :security],
        fn _event, _measurements, _metadata, _config ->
          send(test_pid, :raw_event)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    Memento.transaction!(fn -> Observability.defer([:security], %{count: 1}, %{action: :oper, result: :success}) end)
    refute_received :raw_event
  end

  test "a history query records its duration only for query operations" do
    query_metric = Enum.find(Observability.metrics(), &(&1.name == [:elixircd, :history, :query, :duration, :seconds]))
    assert query_metric.keep.(%{operation: :query})
    refute query_metric.keep.(%{operation: :write_message})

    Observability.emit(
      [:history],
      %{count: 1, rows: 2, duration: System.convert_time_unit(3, :millisecond, :native)},
      %{
        operation: :query
      }
    )

    assert Observability.scrape() =~ "elixircd_history_query_duration_seconds_count 1"

    Observability.emit(
      [:history],
      %{count: 1, rows: 1, duration: System.convert_time_unit(2, :millisecond, :native)},
      %{
        operation: :write_message
      }
    )

    assert Observability.scrape() =~ "elixircd_history_query_duration_seconds_count 1"
  end

  test "job execution latency excludes enqueue events" do
    execution_metric = Enum.find(Observability.metrics(), &(&1.name == [:elixircd, :job, :duration, :seconds]))

    refute execution_metric.keep.(%{result: :enqueued})
    assert execution_metric.keep.(%{result: :success})
    assert execution_metric.keep.(%{result: :failure})
    assert execution_metric.keep.(%{result: :crashed})
  end

  test "management bind override accepts a valid address and rejects malformed input" do
    original = System.get_env("ELIXIRCD_OBSERVABILITY_BIND")

    on_exit(fn ->
      if original,
        do: System.put_env("ELIXIRCD_OBSERVABILITY_BIND", original),
        else: System.delete_env("ELIXIRCD_OBSERVABILITY_BIND")
    end)

    System.put_env("ELIXIRCD_OBSERVABILITY_BIND", "0.0.0.0")
    assert Observability.listener_options()[:ip] == {0, 0, 0, 0}

    System.put_env("ELIXIRCD_OBSERVABILITY_BIND", "invalid")
    assert_raise ArgumentError, "invalid ELIXIRCD_OBSERVABILITY_BIND", &Observability.listener_options/0
  end

  test "readiness and HTTP endpoint report unavailable when Mnesia is unavailable" do
    assert :stopped = :mnesia.stop()

    on_exit(fn ->
      assert :ok = :mnesia.start()
      assert :ok = Memento.wait(Mnesia.all_tables(), 30_000)
    end)

    assert Observability.readiness() == {:error, :database}
    assert OperationalPlug.call(Plug.Test.conn(:get, "/health/ready"), []).status == 503
  end

  test "readiness handles a missing required Mnesia table" do
    tables = Mnesia.all_tables()
    stub(Mnesia, :all_tables, fn -> tables ++ [:missing_required_table] end)

    assert catch_exit(:mnesia.table_info(:missing_required_table, :where_to_read))
    assert Observability.readiness() == {:error, :database}
  end

  test "readiness drops when IRC listeners stop" do
    assert :ok = Supervisor.terminate_child(ElixIRCd, ElixIRCd.Server.Listeners)
    on_exit(fn -> Supervisor.restart_child(ElixIRCd, ElixIRCd.Server.Listeners) end)
    assert Observability.readiness() == {:error, :listeners}
  end

  test "poller reports an empty queue and handles disk command errors without exposing output" do
    stub(Jobs, :get_by_status, fn _status -> [] end)
    assert {:noreply, %{}} = Poller.handle_info(:jobs, %{})
    assert Observability.scrape() =~ "elixircd_jobs_oldest_queued_age_seconds 0"

    stub(System, :cmd, fn "df", _args, _opts -> {"df: private mount detail", 1} end)
    assert {:noreply, %{}} = Poller.handle_info(:sample, %{})
    assert Observability.scrape() =~ "elixircd_data_capacity_bytes 0"

    stub(System, :cmd, fn "df", _args, _opts ->
      {"Filesystem 1024-blocks Used Available Capacity Mounted on\ninvalid\n", 0}
    end)

    assert {:noreply, %{}} = Poller.handle_info(:sample, %{})

    stub(System, :cmd, fn "df", _args, _opts ->
      {"Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda invalid 1 invalid 10% /app/data\n", 0}
    end)

    assert {:noreply, %{}} = Poller.handle_info(:sample, %{})

    stub(System, :cmd, fn "df", _args, _opts -> raise "private mount detail" end)
    log = capture_log(fn -> assert {:noreply, %{}} = Poller.handle_info(:sample, %{}) end)
    assert log =~ "observability sample failed"
    refute log =~ "private mount detail"

    stub(System, :cmd, fn "df", _args, _opts -> exit(:unavailable) end)
    log = capture_log(fn -> assert {:noreply, %{}} = Poller.handle_info(:sample, %{}) end)
    assert log =~ "observability sample failed"
  end
end
