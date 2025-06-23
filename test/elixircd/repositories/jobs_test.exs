defmodule ElixIRCd.Repositories.JobsTest do
  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Repositories.Jobs

  defmodule TestJobModule do
    @behaviour ElixIRCd.Jobs.JobBehavior

    @impl true
    def run(_job), do: :ok
  end

  describe "create/1" do
    test "creates and stores a job in Mnesia" do
      attrs = %{
        module: TestJobModule,
        max_attempts: 5,
        payload: %{data: "test"},
        retry_delay_ms: 10_000
      }

      job =
        Memento.transaction!(fn ->
          Jobs.create(attrs)
        end)

      assert job.module == TestJobModule
      assert job.max_attempts == 5
      assert job.payload == %{data: "test"}
      assert job.retry_delay_ms == 10_000
      assert job.status == :queued
      assert job.current_attempt == 0
      assert job.last_error == nil
      assert is_binary(job.id)

      # Verify it's actually in Mnesia
      {:ok, stored_job} =
        Memento.transaction!(fn ->
          Jobs.get_by_id(job.id)
        end)

      assert stored_job.id == job.id
    end

    test "creates job with default values" do
      job =
        Memento.transaction!(fn ->
          Jobs.create(%{module: TestJobModule})
        end)

      assert job.module == TestJobModule
      assert job.max_attempts == 3
      assert job.payload == %{}
      assert job.retry_delay_ms == 5000
      assert job.repeat_interval_ms == nil
      assert job.status == :queued
      assert job.current_attempt == 0
      assert job.last_error == nil
    end
  end

  describe "get_by_id/1" do
    test "returns job when found" do
      job =
        Memento.transaction!(fn ->
          Jobs.create(%{module: TestJobModule})
        end)

      result =
        Memento.transaction!(fn ->
          Jobs.get_by_id(job.id)
        end)

      assert {:ok, found_job} = result
      assert found_job.id == job.id
      assert found_job.module == TestJobModule
    end

    test "returns error when job not found" do
      result =
        Memento.transaction!(fn ->
          Jobs.get_by_id("nonexistent")
        end)

      assert {:error, :job_not_found} = result
    end
  end

  describe "get_by_status/1" do
    test "returns jobs with specified status" do
      job1 =
        Memento.transaction!(fn ->
          job = Jobs.create(%{module: TestJobModule})
          Jobs.update(job, %{status: :processing})
        end)

      _job2 =
        Memento.transaction!(fn ->
          Jobs.create(%{module: TestJobModule})
        end)

      jobs =
        Memento.transaction!(fn ->
          Jobs.get_by_status(:processing)
        end)

      assert Enum.any?(jobs, &(&1.id == job1.id))
      assert Enum.all?(jobs, &(&1.status == :processing))
    end

    test "returns empty list when no jobs match status" do
      jobs =
        Memento.transaction!(fn ->
          Jobs.get_by_status(:nonexistent_status)
        end)

      assert jobs == []
    end
  end

  describe "get_ready_jobs/0" do
    test "returns jobs that are queued and scheduled to run" do
      now = DateTime.utc_now()
      past_time = DateTime.add(now, -60, :second)

      ready_job =
        Memento.transaction!(fn ->
          Jobs.create(%{module: TestJobModule, scheduled_at: past_time})
        end)

      _future_job =
        Memento.transaction!(fn ->
          future_time = DateTime.add(now, 3600, :second)
          Jobs.create(%{module: TestJobModule, scheduled_at: future_time})
        end)

      jobs =
        Memento.transaction!(fn ->
          Jobs.get_ready_jobs()
        end)

      assert Enum.any?(jobs, &(&1.id == ready_job.id))
      assert Enum.all?(jobs, &(&1.status == :queued))
      assert Enum.all?(jobs, &(DateTime.compare(&1.scheduled_at, now) != :gt))
    end

    test "returns jobs sorted by scheduled_at" do
      now = DateTime.utc_now()
      time1 = DateTime.add(now, -120, :second)
      time2 = DateTime.add(now, -60, :second)

      job1 =
        Memento.transaction!(fn ->
          Jobs.create(%{module: TestJobModule, scheduled_at: time2})
        end)

      job2 =
        Memento.transaction!(fn ->
          Jobs.create(%{module: TestJobModule, scheduled_at: time1})
        end)

      jobs =
        Memento.transaction!(fn ->
          Jobs.get_ready_jobs()
        end)

      relevant_jobs = Enum.filter(jobs, &(&1.id in [job1.id, job2.id]))
      assert length(relevant_jobs) == 2

      [first_job, second_job] = Enum.sort_by(relevant_jobs, & &1.scheduled_at, DateTime)
      assert first_job.id == job2.id
      assert second_job.id == job1.id
    end

    test "returns empty list when no jobs are ready" do
      future_time = DateTime.add(DateTime.utc_now(), 3600, :second)

      _future_job =
        Memento.transaction!(fn ->
          Jobs.create(%{module: TestJobModule, scheduled_at: future_time})
        end)

      ready_jobs =
        Memento.transaction!(fn ->
          Jobs.get_ready_jobs()
        end)

      assert ready_jobs == []
    end
  end

  describe "get_all/0" do
    test "returns all jobs" do
      job1 =
        Memento.transaction!(fn ->
          Jobs.create(%{module: TestJobModule})
        end)

      job2 =
        Memento.transaction!(fn ->
          Jobs.create(%{module: TestJobModule})
        end)

      all_jobs =
        Memento.transaction!(fn ->
          Jobs.get_all()
        end)

      job_ids = Enum.map(all_jobs, & &1.id)
      assert job1.id in job_ids
      assert job2.id in job_ids
    end
  end

  describe "update/2" do
    test "updates job attributes" do
      job =
        Memento.transaction!(fn ->
          Jobs.create(%{module: TestJobModule})
        end)

      updated_job =
        Memento.transaction!(fn ->
          Jobs.update(job, %{status: :processing, current_attempt: 1})
        end)

      assert updated_job.id == job.id
      assert updated_job.status == :processing
      assert updated_job.current_attempt == 1
      assert updated_job.module == TestJobModule

      {:ok, fetched_job} =
        Memento.transaction!(fn ->
          Jobs.get_by_id(job.id)
        end)

      assert fetched_job.status == :processing
      assert fetched_job.current_attempt == 1
    end

    test "updates updated_at timestamp" do
      job =
        Memento.transaction!(fn ->
          Jobs.create(%{module: TestJobModule})
        end)

      original_updated_at = job.updated_at
      Process.sleep(1)

      updated_job =
        Memento.transaction!(fn ->
          Jobs.update(job, %{status: :processing})
        end)

      assert DateTime.compare(updated_job.updated_at, original_updated_at) == :gt
    end
  end

  describe "delete/1" do
    test "removes job from Mnesia" do
      job =
        Memento.transaction!(fn ->
          Jobs.create(%{module: TestJobModule})
        end)

      result =
        Memento.transaction!(fn ->
          Jobs.delete(job)
        end)

      assert result == :ok

      not_found =
        Memento.transaction!(fn ->
          Jobs.get_by_id(job.id)
        end)

      assert {:error, :job_not_found} = not_found
    end
  end

  describe "cleanup_old_jobs/1" do
    test "deletes jobs older than specified days" do
      current_time = DateTime.utc_now()
      old_time = DateTime.add(current_time, -10, :day)
      recent_time = DateTime.add(current_time, -1, :day)

      old_job =
        Memento.transaction!(fn ->
          job = Jobs.create(%{module: TestJobModule})
          old_updated_job = %{job | status: :done, updated_at: old_time}
          Memento.Query.write(old_updated_job)
          old_updated_job
        end)

      recent_job =
        Memento.transaction!(fn ->
          job = Jobs.create(%{module: TestJobModule})
          recent_updated_job = %{job | status: :done, updated_at: recent_time}
          Memento.Query.write(recent_updated_job)
          recent_updated_job
        end)

      deleted_count =
        Memento.transaction!(fn ->
          Jobs.cleanup_old_jobs(5)
        end)

      assert deleted_count >= 1

      {:error, :job_not_found} =
        Memento.transaction!(fn ->
          Jobs.get_by_id(old_job.id)
        end)

      {:ok, _} =
        Memento.transaction!(fn ->
          Jobs.get_by_id(recent_job.id)
        end)
    end

    test "uses default 7 days when no argument provided" do
      current_time = DateTime.utc_now()
      old_time = DateTime.add(current_time, -10, :day)

      _old_job =
        Memento.transaction!(fn ->
          job = Jobs.create(%{module: TestJobModule})
          old_updated_job = %{job | status: :done, updated_at: old_time}
          Memento.Query.write(old_updated_job)
          old_updated_job
        end)

      deleted_count =
        Memento.transaction!(fn ->
          Jobs.cleanup_old_jobs()
        end)

      assert deleted_count >= 1
    end
  end

  describe "Mnesia transactions" do
    test "operations are atomic" do
      job =
        Memento.transaction!(fn ->
          Jobs.create(%{module: TestJobModule})
        end)

      result =
        try do
          Memento.transaction!(fn ->
            Jobs.update(job, %{status: :processing})
            raise "Intentional error"
          end)
        rescue
          _ -> :error
        end

      assert result == :error

      {:ok, unchanged_job} =
        Memento.transaction!(fn ->
          Jobs.get_by_id(job.id)
        end)

      assert unchanged_job.status == :queued
    end
  end
end
