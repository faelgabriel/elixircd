defmodule ElixIRCd.Tables.JobTest do
  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Tables.Job

  describe "new/1" do
    test "creates a job with all required fields" do
      attrs = %{
        type: :test_job,
        payload: %{data: "test"},
        max_attempts: 5,
        retry_delay_ms: 10_000,
        repeat_interval_ms: 60_000
      }

      job = Job.new(attrs)

      assert job.type == :test_job
      assert job.payload == %{data: "test"}
      assert job.status == :queued
      assert job.max_attempts == 5
      assert job.current_attempt == 0
      assert job.retry_delay_ms == 10_000
      assert job.repeat_interval_ms == 60_000
      assert job.last_error == nil
      assert is_binary(job.id)
      assert String.length(job.id) == 32
      assert %DateTime{} = job.created_at
      assert %DateTime{} = job.updated_at
      assert %DateTime{} = job.scheduled_at
    end

    test "creates a job with default values" do
      attrs = %{type: :test_job}

      job = Job.new(attrs)

      assert job.type == :test_job
      assert job.payload == %{}
      assert job.status == :queued
      assert job.max_attempts == 3
      assert job.current_attempt == 0
      assert job.retry_delay_ms == 5000
      assert job.repeat_interval_ms == nil
      assert job.last_error == nil
      assert job.created_at == job.scheduled_at
    end

    test "creates a job with custom scheduled_at" do
      scheduled_time = DateTime.add(DateTime.utc_now(), 3600, :second)
      attrs = %{type: :test_job, scheduled_at: scheduled_time}

      job = Job.new(attrs)

      assert job.scheduled_at == scheduled_time
      assert DateTime.compare(job.created_at, job.scheduled_at) == :lt
    end

    test "generates unique IDs" do
      job1 = Job.new(%{type: :test_job})
      job2 = Job.new(%{type: :test_job})

      assert job1.id != job2.id
    end

    test "raises when type is missing" do
      assert_raise KeyError, fn ->
        Job.new(%{payload: %{}})
      end
    end
  end

  describe "update/2" do
    test "updates job with new attributes" do
      job = Job.new(%{type: :test_job})
      original_updated_at = job.updated_at

      Process.sleep(1)

      updated_job =
        Job.update(job, %{
          status: :processing,
          current_attempt: 1,
          last_error: "some error"
        })

      assert updated_job.status == :processing
      assert updated_job.current_attempt == 1
      assert updated_job.last_error == "some error"
      assert DateTime.compare(updated_job.updated_at, original_updated_at) == :gt

      assert updated_job.id == job.id
      assert updated_job.type == job.type
      assert updated_job.payload == job.payload
      assert updated_job.created_at == job.created_at
    end

    test "automatically updates updated_at timestamp" do
      job = Job.new(%{type: :test_job})
      original_updated_at = job.updated_at

      Process.sleep(1)

      updated_job = Job.update(job, %{status: :done})

      assert DateTime.compare(updated_job.updated_at, original_updated_at) == :gt
    end

    test "handles empty updates" do
      job = Job.new(%{type: :test_job})
      updated_job = Job.update(job, %{})

      assert updated_job.id == job.id
      assert updated_job.type == job.type
      assert updated_job.status == job.status
      assert DateTime.compare(updated_job.updated_at, job.updated_at) == :gt
    end
  end

  describe "job status values" do
    test "supports all expected status values" do
      job = Job.new(%{type: :test_job})

      statuses = [:queued, :processing, :done, :failed]

      for status <- statuses do
        updated_job = Job.update(job, %{status: status})
        assert updated_job.status == status
      end
    end
  end

  describe "id generation" do
    test "generates lowercase hexadecimal string" do
      job = Job.new(%{type: :test_job})

      assert String.match?(job.id, ~r/^[0-9a-f]{32}$/)
    end

    test "generates cryptographically strong random IDs" do
      ids = for _ <- 1..1000, do: Job.new(%{type: :test_job}).id
      unique_ids = Enum.uniq(ids)

      assert length(ids) == length(unique_ids)
    end
  end
end
