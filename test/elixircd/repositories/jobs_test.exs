defmodule ElixIRCd.Repositories.JobsTest do
  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Repositories.Jobs

  describe "create/1" do
    test "creates and stores a job in Mnesia" do
      params = %{
        type: :test_job,
        payload: %{data: "test"},
        max_attempts: 5,
        retry_delay_ms: 10_000
      }

      job =
        Memento.transaction!(fn ->
          Jobs.create(params)
        end)

      assert job.type == :test_job
      assert job.payload == %{data: "test"}
      assert job.status == :queued
      assert job.max_attempts == 5

      {:ok, fetched_job} =
        Memento.transaction!(fn ->
          Jobs.get_by_id(job.id)
        end)

      assert fetched_job.id == job.id
      assert fetched_job.type == job.type
    end

    test "creates job with default values" do
      params = %{type: :simple_job}

      job =
        Memento.transaction!(fn ->
          Jobs.create(params)
        end)

      assert job.type == :simple_job
      assert job.payload == %{}
      assert job.max_attempts == 3
      assert job.retry_delay_ms == 5000
    end
  end

  describe "get_by_id/1" do
    test "returns job when found" do
      job =
        Memento.transaction!(fn ->
          Jobs.create(%{type: :test_job})
        end)

      result =
        Memento.transaction!(fn ->
          Jobs.get_by_id(job.id)
        end)

      assert {:ok, fetched_job} = result
      assert fetched_job.id == job.id
      assert fetched_job.type == job.type
    end

    test "returns error when job not found" do
      result =
        Memento.transaction!(fn ->
          Jobs.get_by_id("nonexistent_id")
        end)

      assert result == {:error, :job_not_found}
    end
  end

  describe "get_by_status/1" do
    test "returns jobs with specified status" do
      Memento.transaction!(fn ->
        job1 = Jobs.create(%{type: :job1})
        job2 = Jobs.create(%{type: :job2})
        job3 = Jobs.create(%{type: :job3})

        Jobs.update(job1, %{status: :processing})
        Jobs.update(job2, %{status: :done})

        queued_jobs = Jobs.get_by_status(:queued)
        processing_jobs = Jobs.get_by_status(:processing)
        done_jobs = Jobs.get_by_status(:done)

        assert length(queued_jobs) == 1
        assert length(processing_jobs) == 1
        assert length(done_jobs) == 1

        assert hd(queued_jobs).id == job3.id
        assert hd(processing_jobs).id == job1.id
        assert hd(done_jobs).id == job2.id
      end)
    end

    test "returns empty list when no jobs with status exist" do
      result =
        Memento.transaction!(fn ->
          Jobs.get_by_status(:failed)
        end)

      assert result == []
    end
  end

  describe "get_ready_jobs/0" do
    test "returns jobs that are queued and scheduled to run" do
      now = DateTime.utc_now()
      past_time = DateTime.add(now, -3600, :second)
      future_time = DateTime.add(now, 3600, :second)

      Memento.transaction!(fn ->
        job1 = Jobs.create(%{type: :ready_job, scheduled_at: past_time})
        _job2 = Jobs.create(%{type: :future_job, scheduled_at: future_time})
        job3 = Jobs.create(%{type: :processing_job, scheduled_at: past_time})
        Jobs.update(job3, %{status: :processing})

        ready_jobs = Jobs.get_ready_jobs()

        assert length(ready_jobs) == 1
        assert hd(ready_jobs).id == job1.id
      end)
    end

    test "returns jobs sorted by scheduled_at" do
      now = DateTime.utc_now()
      time1 = DateTime.add(now, -7200, :second)
      time2 = DateTime.add(now, -3600, :second)
      time3 = DateTime.add(now, -1800, :second)

      Memento.transaction!(fn ->
        job1 = Jobs.create(%{type: :job1, scheduled_at: time2})
        job2 = Jobs.create(%{type: :job2, scheduled_at: time1})
        job3 = Jobs.create(%{type: :job3, scheduled_at: time3})

        ready_jobs = Jobs.get_ready_jobs()

        assert length(ready_jobs) == 3
        assert Enum.at(ready_jobs, 0).id == job2.id
        assert Enum.at(ready_jobs, 1).id == job1.id
        assert Enum.at(ready_jobs, 2).id == job3.id
      end)
    end

    test "returns empty list when no jobs are ready" do
      future_time = DateTime.add(DateTime.utc_now(), 3600, :second)

      Memento.transaction!(fn ->
        _job = Jobs.create(%{type: :future_job, scheduled_at: future_time})

        ready_jobs = Jobs.get_ready_jobs()
        assert ready_jobs == []
      end)
    end
  end

  describe "get_all/0" do
    test "returns all jobs" do
      Memento.transaction!(fn ->
        job1 = Jobs.create(%{type: :job1})
        job2 = Jobs.create(%{type: :job2})
        job3 = Jobs.create(%{type: :job3})

        all_jobs = Jobs.get_all()

        assert length(all_jobs) == 3
        job_ids = Enum.map(all_jobs, & &1.id)
        assert job1.id in job_ids
        assert job2.id in job_ids
        assert job3.id in job_ids
      end)
    end

    test "returns empty list when no jobs exist" do
      result =
        Memento.transaction!(fn ->
          Jobs.get_all()
        end)

      assert result == []
    end
  end

  describe "update/2" do
    test "updates job attributes" do
      job =
        Memento.transaction!(fn ->
          Jobs.create(%{type: :test_job})
        end)

      updated_job =
        Memento.transaction!(fn ->
          Jobs.update(job, %{
            status: :processing,
            current_attempt: 1,
            last_error: "test error"
          })
        end)

      assert updated_job.status == :processing
      assert updated_job.current_attempt == 1
      assert updated_job.last_error == "test error"
      assert updated_job.id == job.id

      {:ok, fetched_job} =
        Memento.transaction!(fn ->
          Jobs.get_by_id(job.id)
        end)

      assert fetched_job.status == :processing
      assert fetched_job.current_attempt == 1
      assert fetched_job.last_error == "test error"
    end

    test "updates updated_at timestamp" do
      job =
        Memento.transaction!(fn ->
          Jobs.create(%{type: :test_job})
        end)

      original_updated_at = job.updated_at
      Process.sleep(1)

      updated_job =
        Memento.transaction!(fn ->
          Jobs.update(job, %{status: :done})
        end)

      assert DateTime.compare(updated_job.updated_at, original_updated_at) == :gt
    end
  end

  describe "delete/1" do
    test "removes job from Mnesia" do
      job =
        Memento.transaction!(fn ->
          Jobs.create(%{type: :test_job})
        end)

      {:ok, _} =
        Memento.transaction!(fn ->
          Jobs.get_by_id(job.id)
        end)

      Memento.transaction!(fn ->
        Jobs.delete(job)
      end)

      result =
        Memento.transaction!(fn ->
          Jobs.get_by_id(job.id)
        end)

      assert result == {:error, :job_not_found}
    end
  end

  describe "cleanup_old_jobs/1" do
    test "deletes jobs older than specified days" do
      now = DateTime.utc_now()
      old_time = DateTime.add(now, -10, :day)
      recent_time = DateTime.add(now, -3, :day)

      Memento.transaction!(fn ->
        old_done_job = Jobs.create(%{type: :old_done})
        old_failed_job = Jobs.create(%{type: :old_failed})
        recent_done_job = Jobs.create(%{type: :recent_done})
        old_queued_job = Jobs.create(%{type: :old_queued})

        write_job_with_timestamp(old_done_job, :done, old_time)
        write_job_with_timestamp(old_failed_job, :failed, old_time)
        write_job_with_timestamp(recent_done_job, :done, recent_time)

        deleted_count = Jobs.cleanup_old_jobs(7)
        assert deleted_count == 2

        remaining_jobs = Jobs.get_all()
        remaining_ids = Enum.map(remaining_jobs, & &1.id)

        assert recent_done_job.id in remaining_ids
        assert old_queued_job.id in remaining_ids
        refute old_done_job.id in remaining_ids
        refute old_failed_job.id in remaining_ids
      end)
    end

    test "uses default 7 days when no argument provided" do
      now = DateTime.utc_now()
      old_time = DateTime.add(now, -10, :day)

      Memento.transaction!(fn ->
        old_job = Jobs.create(%{type: :old_job})
        write_job_with_timestamp(old_job, :done, old_time)

        deleted_count = Jobs.cleanup_old_jobs()
        assert deleted_count == 1
      end)
    end

    test "returns 0 when no jobs to clean up" do
      result =
        Memento.transaction!(fn ->
          Jobs.cleanup_old_jobs(7)
        end)

      assert result == 0
    end
  end

  describe "Mnesia transactions" do
    test "operations are atomic" do
      result =
        Memento.transaction!(fn ->
          job1 = Jobs.create(%{type: :job1})
          job2 = Jobs.create(%{type: :job2})

          Jobs.update(job1, %{status: :processing})
          Jobs.update(job2, %{status: :done})

          {job1.id, job2.id}
        end)

      {job1_id, job2_id} = result

      Memento.transaction!(fn ->
        {:ok, job1} = Jobs.get_by_id(job1_id)
        {:ok, job2} = Jobs.get_by_id(job2_id)

        assert job1.status == :processing
        assert job2.status == :done
      end)
    end
  end

  defp write_job_with_timestamp(job, status, timestamp) do
    updated_job = %{job | status: status, updated_at: timestamp}
    Memento.Query.write(updated_job)
  end
end
