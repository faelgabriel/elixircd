defmodule ElixIRCd.JobQueueTest do
  use ElixIRCd.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias ElixIRCd.JobQueue
  alias ElixIRCd.Jobs.RegisteredNickExpiration
  alias ElixIRCd.Jobs.UnverifiedNickExpiration
  alias ElixIRCd.Repositories.Jobs
  alias ElixIRCd.Tables.Job

  defmodule TestJobModule do
    @behaviour ElixIRCd.Jobs.JobBehavior

    @impl true
    def run(_job), do: :ok
  end

  defmodule UnknownJobModule do
    @behaviour ElixIRCd.Jobs.JobBehavior

    @impl true
    def run(_job) do
      {:error, "Unknown job module"}
    end
  end

  @spec wait_until((-> boolean()), non_neg_integer()) :: :ok
  defp wait_until(fun, attempts \\ 50) do
    if fun.() do
      :ok
    else
      if attempts > 0 do
        Process.sleep(10)
        wait_until(fun, attempts - 1)
      else
        flunk("Condition not met in time")
      end
    end
  end

  @spec wait_until_with_result((-> {:ok, any()} | :ok | any()), non_neg_integer()) :: any()
  defp wait_until_with_result(fun, attempts \\ 50) do
    case fun.() do
      {:ok, result} ->
        result

      :ok ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_until_with_result(fun, attempts - 1)

      _ ->
        flunk("Condition not met in time")
    end
  end

  @spec wait_for_job_status_change(String.t(), atom()) :: Job.t()
  defp wait_for_job_status_change(job_id, initial_status) do
    wait_until_with_result(fn -> check_job_status_change(job_id, initial_status) end)
  end

  @spec wait_for_job_status(String.t(), atom()) :: Job.t()
  defp wait_for_job_status(job_id, expected_status) do
    wait_until_with_result(fn -> check_job_status(job_id, expected_status) end)
  end

  @spec wait_for_job_with_error(String.t()) :: Job.t()
  defp wait_for_job_with_error(job_id) do
    wait_until_with_result(fn -> check_job_with_error(job_id) end)
  end

  @spec check_job_status_change(String.t(), atom()) :: {:ok, Job.t()} | :retry
  defp check_job_status_change(job_id, initial_status) do
    case Memento.transaction!(fn -> Jobs.get_by_id(job_id) end) do
      {:ok, job} when job.status != initial_status -> {:ok, job}
      {:ok, _job} -> :retry
      error -> flunk("Failed to get job: #{inspect(error)}")
    end
  end

  @spec check_job_status(String.t(), atom()) :: {:ok, Job.t()} | :retry
  defp check_job_status(job_id, expected_status) do
    case Memento.transaction!(fn -> Jobs.get_by_id(job_id) end) do
      {:ok, job} when job.status == expected_status -> {:ok, job}
      {:ok, _job} -> :retry
      error -> flunk("Failed to get job: #{inspect(error)}")
    end
  end

  @spec check_job_with_error(String.t()) :: {:ok, Job.t()} | :retry
  defp check_job_with_error(job_id) do
    case Memento.transaction!(fn -> Jobs.get_by_id(job_id) end) do
      {:ok, job} when job.current_attempt >= 1 and job.last_error != nil -> {:ok, job}
      {:ok, _job} -> :retry
      error -> flunk("Failed to get job: #{inspect(error)}")
    end
  end

  describe "enqueue/3" do
    test "enqueues a job successfully with defaults" do
      job = JobQueue.enqueue(RegisteredNickExpiration)

      assert job.module == RegisteredNickExpiration
      assert job.payload == %{}
      assert job.status == :queued
      assert job.max_attempts == 3
      assert job.retry_delay_ms == 5000
      assert job.repeat_interval_ms == nil
      assert job.current_attempt == 0

      {:ok, fetched_job} =
        Memento.transaction!(fn ->
          Jobs.get_by_id(job.id)
        end)

      assert fetched_job.id == job.id
    end

    test "enqueues a job with custom payload" do
      job = JobQueue.enqueue(RegisteredNickExpiration, %{data: "test"})

      assert job.module == RegisteredNickExpiration
      assert job.payload == %{data: "test"}
      assert job.status == :queued
    end

    test "enqueues job with all custom options" do
      scheduled_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      job =
        JobQueue.enqueue(RegisteredNickExpiration, %{custom: "data"},
          scheduled_at: scheduled_at,
          max_attempts: 5,
          retry_delay_ms: 10_000,
          repeat_interval_ms: 60_000
        )

      assert job.scheduled_at == scheduled_at
      assert job.max_attempts == 5
      assert job.retry_delay_ms == 10_000
      assert job.repeat_interval_ms == 60_000
      assert job.payload == %{custom: "data"}
    end

    test "raises ArgumentError when job module does not implement JobBehavior" do
      defmodule InvalidJobModule do
        # This module does not implement the JobBehavior
      end

      assert_raise ArgumentError, ~r/Module.*does not implement.*JobBehavior/, fn ->
        JobQueue.enqueue(InvalidJobModule)
      end
    end
  end

  describe "get_stats/0" do
    test "returns correct job statistics" do
      Memento.transaction!(fn ->
        Jobs.create(%{module: TestJobModule})
        job2 = Jobs.create(%{module: TestJobModule})
        Jobs.update(job2, %{status: :processing})
        job3 = Jobs.create(%{module: TestJobModule})
        job4 = Jobs.create(%{module: TestJobModule})
        Jobs.update(job3, %{status: :done})
        Jobs.update(job4, %{status: :failed})
      end)

      stats = JobQueue.get_stats()

      assert stats.total == 4
      assert stats.queued == 1
      assert stats.processing == 1
      assert stats.done == 1
      assert stats.failed == 1
    end

    test "returns zeros when no jobs exist" do
      stats = JobQueue.get_stats()

      assert stats.total == 0
      assert stats.queued == 0
      assert stats.processing == 0
      assert stats.done == 0
      assert stats.failed == 0
    end
  end

  describe "get_detailed_stats/0" do
    test "returns detailed statistics" do
      now = DateTime.utc_now()
      overdue_time = DateTime.add(now, -3600, :second)
      future_time = DateTime.add(now, 3600, :second)

      Memento.transaction!(fn ->
        _job1 = Jobs.create(%{module: TestJobModule, scheduled_at: overdue_time})
        job2 = Jobs.create(%{module: RegisteredNickExpiration, scheduled_at: future_time})
        Jobs.update(job2, %{status: :failed, updated_at: now})

        old_time = DateTime.add(now, -25 * 60 * 60, :second)
        job3 = Jobs.create(%{module: UnverifiedNickExpiration, scheduled_at: future_time})
        Jobs.update(job3, %{status: :failed, updated_at: old_time})

        Jobs.create(%{module: TestJobModule, scheduled_at: future_time})
        Jobs.create(%{module: TestJobModule, scheduled_at: future_time})
      end)

      stats = JobQueue.get_detailed_stats()

      assert stats.total == 5
      assert stats.overdue == 1
      assert stats.jobs_by_type[TestJobModule] == 3
      assert stats.jobs_by_type[RegisteredNickExpiration] == 1
      assert stats.jobs_by_type[UnverifiedNickExpiration] == 1
      assert stats.recent_failures_24h >= 1
    end

    test "returns empty detailed stats when no jobs exist" do
      stats = JobQueue.get_detailed_stats()

      assert stats.total == 0
      assert stats.overdue == 0
      assert stats.jobs_by_type == %{}
      assert stats.recent_failures_24h == 0
    end
  end

  describe "cancel_job/1" do
    test "cancels a queued job" do
      job = JobQueue.enqueue(TestJobModule)

      assert :ok = JobQueue.cancel_job(job.id)

      {:ok, updated_job} = Memento.transaction!(fn -> Jobs.get_by_id(job.id) end)
      assert updated_job.status == :failed
      assert updated_job.last_error == "Cancelled by admin"
    end

    test "cancels a processing job" do
      Memento.transaction!(fn ->
        job = Jobs.create(%{module: TestJobModule})
        Jobs.update(job, %{status: :processing})

        assert :ok = JobQueue.cancel_job(job.id)

        {:ok, updated_job} = Jobs.get_by_id(job.id)
        assert updated_job.status == :failed
        assert updated_job.last_error == "Cancelled by admin"
      end)
    end

    test "cannot cancel a done job" do
      Memento.transaction!(fn ->
        job = Jobs.create(%{module: TestJobModule})
        Jobs.update(job, %{status: :done})

        log_output =
          capture_log(fn ->
            assert {:error, :job_not_cancellable} = JobQueue.cancel_job(job.id)
          end)

        {:ok, updated_job} = Jobs.get_by_id(job.id)
        assert updated_job.status == :done
        assert log_output =~ "Cannot cancel job in status"
      end)
    end

    test "cannot cancel a failed job" do
      Memento.transaction!(fn ->
        job = Jobs.create(%{module: TestJobModule})
        Jobs.update(job, %{status: :failed})

        log_output =
          capture_log(fn ->
            assert {:error, :job_not_cancellable} = JobQueue.cancel_job(job.id)
          end)

        {:ok, updated_job} = Jobs.get_by_id(job.id)
        assert updated_job.status == :failed
        assert log_output =~ "Cannot cancel job in status"
      end)
    end

    test "returns error for non-existent job" do
      assert {:error, :job_not_found} = JobQueue.cancel_job("non-existent-id")
    end
  end

  describe "retry_job/1" do
    test "retries a failed job" do
      Memento.transaction!(fn ->
        job = Jobs.create(%{module: TestJobModule})
        Jobs.update(job, %{status: :failed, current_attempt: 2, last_error: "Previous error"})

        assert :ok = JobQueue.retry_job(job.id)

        {:ok, updated_job} = Jobs.get_by_id(job.id)
        assert updated_job.status == :queued
        assert updated_job.current_attempt == 0
        assert updated_job.last_error == nil
        assert DateTime.diff(DateTime.utc_now(), updated_job.scheduled_at, :second) < 5
      end)
    end

    test "cannot retry a queued job" do
      job = JobQueue.enqueue(TestJobModule)

      log_output =
        capture_log(fn ->
          assert {:error, :job_not_retryable} = JobQueue.retry_job(job.id)
        end)

      {:ok, updated_job} = Memento.transaction!(fn -> Jobs.get_by_id(job.id) end)
      assert updated_job.status == :queued
      assert log_output =~ "Cannot retry job in status"
    end

    test "cannot retry a processing job" do
      Memento.transaction!(fn ->
        job = Jobs.create(%{module: TestJobModule})
        Jobs.update(job, %{status: :processing})

        log_output =
          capture_log(fn ->
            assert {:error, :job_not_retryable} = JobQueue.retry_job(job.id)
          end)

        {:ok, updated_job} = Jobs.get_by_id(job.id)
        assert updated_job.status == :processing
        assert log_output =~ "Cannot retry job in status"
      end)
    end

    test "cannot retry a done job" do
      Memento.transaction!(fn ->
        job = Jobs.create(%{module: TestJobModule})
        Jobs.update(job, %{status: :done})

        log_output =
          capture_log(fn ->
            assert {:error, :job_not_retryable} = JobQueue.retry_job(job.id)
          end)

        {:ok, updated_job} = Jobs.get_by_id(job.id)
        assert updated_job.status == :done
        assert log_output =~ "Cannot retry job in status"
      end)
    end

    test "returns error for non-existent job" do
      assert {:error, :job_not_found} = JobQueue.retry_job("non-existent-id")
    end
  end

  describe "list_jobs/1" do
    test "lists all jobs without filters" do
      job1 = JobQueue.enqueue(TestJobModule)
      job2 = JobQueue.enqueue(RegisteredNickExpiration)

      jobs = JobQueue.list_jobs()
      assert length(jobs) == 2
      job_ids = Enum.map(jobs, & &1.id)
      assert job1.id in job_ids
      assert job2.id in job_ids
    end

    test "filters jobs by status" do
      job1 = JobQueue.enqueue(TestJobModule)

      Memento.transaction!(fn ->
        job2 = Jobs.create(%{module: TestJobModule})
        Jobs.update(job2, %{status: :done})
      end)

      queued_jobs = JobQueue.list_jobs(status: :queued)
      assert length(queued_jobs) == 1
      assert hd(queued_jobs).id == job1.id

      done_jobs = JobQueue.list_jobs(status: :done)
      assert length(done_jobs) == 1
      assert hd(done_jobs).status == :done
    end

    test "filters jobs by type" do
      job1 = JobQueue.enqueue(TestJobModule)
      _job2 = JobQueue.enqueue(RegisteredNickExpiration)

      type1_jobs = JobQueue.list_jobs(type: TestJobModule)
      assert length(type1_jobs) == 1
      assert hd(type1_jobs).id == job1.id
      assert hd(type1_jobs).module == TestJobModule
    end

    @tag :capture_log
    test "limits number of jobs returned" do
      JobQueue.enqueue(TestJobModule)
      JobQueue.enqueue(RegisteredNickExpiration)
      JobQueue.enqueue(TestJobModule)

      limited_jobs = JobQueue.list_jobs(limit: 2)
      assert length(limited_jobs) == 2
    end

    @tag :capture_log
    test "combines multiple filters" do
      JobQueue.enqueue(TestJobModule)
      JobQueue.enqueue(TestJobModule)
      JobQueue.enqueue(RegisteredNickExpiration)

      filtered_jobs = JobQueue.list_jobs(type: TestJobModule, limit: 1)
      assert length(filtered_jobs) == 1
      assert hd(filtered_jobs).module == TestJobModule
    end

    @tag :capture_log
    test "returns empty list when no jobs match filters" do
      JobQueue.enqueue(TestJobModule)

      jobs = JobQueue.list_jobs(status: :done)
      assert jobs == []

      jobs = JobQueue.list_jobs(type: :non_existent)
      assert jobs == []
    end
  end

  describe "cleanup_old_jobs/1" do
    test "cleans up old jobs with default days_to_keep" do
      now = DateTime.utc_now()
      old_time = DateTime.add(now, -8, :day)
      recent_time = DateTime.add(now, -5, :day)

      Memento.transaction!(fn ->
        old_job = Job.new(%{module: TestJobModule})
        recent_job = Job.new(%{module: TestJobModule})
        old_job_with_timestamp = %{old_job | status: :done, updated_at: old_time}
        recent_job_with_timestamp = %{recent_job | status: :done, updated_at: recent_time}
        Memento.Query.write(old_job_with_timestamp)
        Memento.Query.write(recent_job_with_timestamp)
      end)

      deleted_count = JobQueue.cleanup_old_jobs()
      assert deleted_count == 1

      remaining_jobs = Memento.transaction!(fn -> Jobs.get_all() end)
      assert length(remaining_jobs) == 1
      assert hd(remaining_jobs).module == TestJobModule
    end

    test "cleans up old jobs with custom days_to_keep" do
      now = DateTime.utc_now()
      old_time = DateTime.add(now, -4, :day)
      recent_time = DateTime.add(now, -2, :day)

      Memento.transaction!(fn ->
        old_job = Job.new(%{module: TestJobModule})
        recent_job = Job.new(%{module: TestJobModule})
        old_job_with_timestamp = %{old_job | status: :done, updated_at: old_time}
        recent_job_with_timestamp = %{recent_job | status: :done, updated_at: recent_time}
        Memento.Query.write(old_job_with_timestamp)
        Memento.Query.write(recent_job_with_timestamp)
      end)

      deleted_count = JobQueue.cleanup_old_jobs(3)
      assert deleted_count == 1

      remaining_jobs = Memento.transaction!(fn -> Jobs.get_all() end)
      assert length(remaining_jobs) == 1
      assert hd(remaining_jobs).module == TestJobModule
    end

    test "returns 0 when no old jobs to clean" do
      JobQueue.enqueue(TestJobModule)

      deleted_count = JobQueue.cleanup_old_jobs(1)
      assert deleted_count == 0
    end
  end

  describe "job polling and execution" do
    @tag :capture_log
    test "processes ready jobs when polled" do
      job = JobQueue.enqueue(RegisteredNickExpiration)

      pid = Process.whereis(JobQueue)

      send(pid, :poll_jobs)
      updated_job = wait_for_job_status_change(job.id, :queued)
      assert updated_job.current_attempt >= 1
    end

    test "does not process future-scheduled jobs" do
      future_time = DateTime.add(DateTime.utc_now(), 3600, :second)
      job = JobQueue.enqueue(RegisteredNickExpiration, %{}, scheduled_at: future_time)

      pid = Process.whereis(JobQueue)
      send(pid, :poll_jobs)

      wait_until(fn ->
        case Memento.transaction!(fn -> Jobs.get_by_id(job.id) end) do
          {:ok, updated_job} -> updated_job.status == :queued and updated_job.current_attempt == 0
          _ -> false
        end
      end)

      {:ok, updated_job} = Memento.transaction!(fn -> Jobs.get_by_id(job.id) end)
      assert updated_job.status == :queued
      assert updated_job.current_attempt == 0
    end

    @tag :capture_log
    test "handles job execution with unknown type" do
      job = JobQueue.enqueue(UnknownJobModule)

      pid = Process.whereis(JobQueue)
      send(pid, :poll_jobs)

      updated_job =
        wait_until_with_result(fn ->
          case Memento.transaction!(fn -> Jobs.get_by_id(job.id) end) do
            {:ok, job_record} when job_record.last_error != nil -> {:ok, job_record}
            {:ok, _job_record} -> :retry
            error -> flunk("Failed to get job: #{inspect(error)}")
          end
        end)

      assert updated_job.status in [:queued, :failed]
      assert updated_job.last_error =~ "Unknown job module"
    end

    @tag :capture_log
    test "handles job execution that exceeds max attempts" do
      job = JobQueue.enqueue(UnknownJobModule, %{}, max_attempts: 1, retry_delay_ms: 100)

      pid = Process.whereis(JobQueue)

      send(pid, :poll_jobs)
      send(pid, :poll_jobs)

      failed_job = wait_for_job_status(job.id, :failed)
      assert failed_job.current_attempt == 1
    end

    @tag :capture_log
    test "schedules recurring jobs" do
      job = JobQueue.enqueue(RegisteredNickExpiration, %{}, repeat_interval_ms: 1000, max_attempts: 1)

      pid = Process.whereis(JobQueue)

      send(pid, :poll_jobs)
      completed_job = wait_for_job_status(job.id, :done)
      assert completed_job.status == :done

      all_jobs = Memento.transaction!(fn -> Jobs.get_all() end)

      recurring_jobs =
        Enum.filter(all_jobs, fn j ->
          j.id != job.id and j.module == RegisteredNickExpiration
        end)

      assert length(recurring_jobs) >= 1
      recurring_job = hd(recurring_jobs)
      assert recurring_job.repeat_interval_ms == 1000
    end

    @tag :capture_log
    test "executes job and logs execution information" do
      job = JobQueue.enqueue(RegisteredNickExpiration)

      pid = Process.whereis(JobQueue)
      send(pid, :poll_jobs)

      updated_job = wait_for_job_status_change(job.id, :queued)
      assert updated_job.current_attempt >= 1
    end
  end

  describe "job dispatch logic" do
    test "handles registered_nick_expiration jobs" do
      job = JobQueue.enqueue(RegisteredNickExpiration)
      assert job.module == RegisteredNickExpiration
    end

    test "handles unverified_nick_expiration jobs" do
      job = JobQueue.enqueue(UnverifiedNickExpiration)
      assert job.module == UnverifiedNickExpiration
    end
  end

  describe "job status transitions" do
    @tag :capture_log
    test "job goes from queued to processing to done" do
      job = JobQueue.enqueue(RegisteredNickExpiration)

      assert job.status == :queued
      assert job.current_attempt == 0

      pid = Process.whereis(JobQueue)

      send(pid, :poll_jobs)
      final_job = wait_for_job_status_change(job.id, :queued)
      assert final_job.current_attempt >= 1
      assert final_job.status in [:done, :queued]
    end

    @tag :capture_log
    test "job retry logic with failure" do
      job = JobQueue.enqueue(UnknownJobModule, %{}, max_attempts: 2, retry_delay_ms: 100)

      pid = Process.whereis(JobQueue)

      send(pid, :poll_jobs)
      send(pid, :poll_jobs)

      final_job = wait_for_job_with_error(job.id)
      assert final_job.current_attempt >= 1
      assert final_job.last_error != nil
    end
  end

  describe "recover_stuck_jobs/0" do
    test "recovers jobs stuck in processing state" do
      now = DateTime.utc_now()
      future_time = DateTime.add(now, 3600, :second)

      stuck_job1 = JobQueue.enqueue(RegisteredNickExpiration, %{}, scheduled_at: future_time)
      stuck_job2 = JobQueue.enqueue(UnverifiedNickExpiration, %{}, scheduled_at: future_time)
      queued_job = JobQueue.enqueue(RegisteredNickExpiration, %{}, scheduled_at: future_time)
      done_job = JobQueue.enqueue(UnverifiedNickExpiration, %{}, scheduled_at: future_time)
      failed_job = JobQueue.enqueue(RegisteredNickExpiration, %{}, scheduled_at: future_time)

      Memento.transaction!(fn ->
        {:ok, job1} = Jobs.get_by_id(stuck_job1.id)
        Jobs.update(job1, %{status: :processing, current_attempt: 1})

        {:ok, job2} = Jobs.get_by_id(stuck_job2.id)
        Jobs.update(job2, %{status: :processing, current_attempt: 2})

        {:ok, job_done} = Jobs.get_by_id(done_job.id)
        Jobs.update(job_done, %{status: :done})

        {:ok, job_failed} = Jobs.get_by_id(failed_job.id)
        Jobs.update(job_failed, %{status: :failed})
      end)

      log_output =
        capture_log(fn ->
          pid = Process.whereis(JobQueue)
          send(pid, :recover_stuck_jobs)

          wait_until(fn ->
            case Memento.transaction!(fn -> Jobs.get_by_id(stuck_job1.id) end) do
              {:ok, job} -> job.status == :queued
              _ -> false
            end
          end)
        end)

      Memento.transaction!(fn ->
        {:ok, recovered_job1} = Jobs.get_by_id(stuck_job1.id)
        assert recovered_job1.status == :queued
        assert DateTime.compare(recovered_job1.scheduled_at, now) == :gt

        {:ok, recovered_job2} = Jobs.get_by_id(stuck_job2.id)
        assert recovered_job2.status == :queued
        assert DateTime.compare(recovered_job2.scheduled_at, now) == :gt

        {:ok, unchanged_queued} = Jobs.get_by_id(queued_job.id)
        assert unchanged_queued.status in [:queued, :done]

        {:ok, unchanged_done} = Jobs.get_by_id(done_job.id)
        assert unchanged_done.status == :done

        {:ok, unchanged_failed} = Jobs.get_by_id(failed_job.id)
        assert unchanged_failed.status == :failed
      end)

      assert log_output =~
               "Recovering stuck job from previous crash: #{inspect(RegisteredNickExpiration)} (id: #{stuck_job1.id})"

      assert log_output =~
               "Recovering stuck job from previous crash: #{inspect(UnverifiedNickExpiration)} (id: #{stuck_job2.id})"
    end

    test "does nothing when no stuck jobs exist" do
      future_time = DateTime.add(DateTime.utc_now(), 3600, :second)

      _queued_job = JobQueue.enqueue(RegisteredNickExpiration, %{}, scheduled_at: future_time)
      done_job = JobQueue.enqueue(UnverifiedNickExpiration, %{}, scheduled_at: future_time)
      failed_job = JobQueue.enqueue(RegisteredNickExpiration, %{}, scheduled_at: future_time)

      Memento.transaction!(fn ->
        {:ok, job_done} = Jobs.get_by_id(done_job.id)
        Jobs.update(job_done, %{status: :done})

        {:ok, job_failed} = Jobs.get_by_id(failed_job.id)
        Jobs.update(job_failed, %{status: :failed})
      end)

      log_output =
        capture_log(fn ->
          pid = Process.whereis(JobQueue)
          send(pid, :recover_stuck_jobs)

          wait_until(fn -> Process.alive?(pid) end)
        end)

      refute log_output =~ "Recovering stuck job"
      refute log_output =~ "Recovered"
    end

    test "reschedules stuck jobs with correct retry delay" do
      now = DateTime.utc_now()
      custom_retry_delay = 60_000

      job = JobQueue.enqueue(RegisteredNickExpiration, %{}, retry_delay_ms: custom_retry_delay)

      Memento.transaction!(fn ->
        {:ok, job_record} = Jobs.get_by_id(job.id)
        Jobs.update(job_record, %{status: :processing, current_attempt: 1})
      end)

      capture_log(fn ->
        pid = Process.whereis(JobQueue)
        send(pid, :recover_stuck_jobs)

        wait_for_job_status(job.id, :queued)
      end)

      Memento.transaction!(fn ->
        {:ok, recovered_job} = Jobs.get_by_id(job.id)
        assert recovered_job.status == :queued

        expected_time = DateTime.add(now, custom_retry_delay, :millisecond)
        time_diff = DateTime.diff(recovered_job.scheduled_at, expected_time, :millisecond)

        assert abs(time_diff) < 5000
      end)
    end

    test "preserves job attempt count during recovery" do
      future_time = DateTime.add(DateTime.utc_now(), 3600, :second)
      job = JobQueue.enqueue(RegisteredNickExpiration, %{}, scheduled_at: future_time)

      original_attempt = 2

      Memento.transaction!(fn ->
        {:ok, job_record} = Jobs.get_by_id(job.id)
        Jobs.update(job_record, %{status: :processing, current_attempt: original_attempt})
      end)

      capture_log(fn ->
        pid = Process.whereis(JobQueue)
        send(pid, :recover_stuck_jobs)

        wait_until(fn ->
          case Memento.transaction!(fn -> Jobs.get_by_id(job.id) end) do
            {:ok, recovered_job} -> recovered_job.status == :queued
            _ -> false
          end
        end)
      end)

      Memento.transaction!(fn ->
        {:ok, recovered_job} = Jobs.get_by_id(job.id)
        assert recovered_job.status == :queued
        assert recovered_job.current_attempt == original_attempt
      end)
    end
  end
end
