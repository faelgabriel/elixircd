defmodule ElixIRCd.Tables.JobTest do
  use ElixIRCd.DataCase, async: true

  alias ElixIRCd.Tables.Job

  defmodule TestJobModule do
    @behaviour ElixIRCd.Jobs.JobBehavior

    @impl true
    def run(_job), do: :ok
  end

  describe "new/1" do
    test "creates a job with all required fields" do
      attrs = %{
        module: TestJobModule,
        max_attempts: 5,
        payload: %{data: "test"},
        retry_delay_ms: 10_000,
        repeat_interval_ms: 60_000
      }

      job = Job.new(attrs)

      assert job.module == TestJobModule
      assert job.max_attempts == 5
      assert job.payload == %{data: "test"}
      assert job.retry_delay_ms == 10_000
      assert job.repeat_interval_ms == 60_000
      assert job.status == :queued
      assert job.current_attempt == 0
      assert job.last_error == nil
      assert %DateTime{} = job.scheduled_at
      assert %DateTime{} = job.created_at
      assert %DateTime{} = job.updated_at
      assert is_binary(job.id)
    end

    test "creates a job with default values" do
      attrs = %{module: TestJobModule}
      job = Job.new(attrs)

      assert job.module == TestJobModule
      assert job.max_attempts == 3
      assert job.payload == %{}
      assert job.retry_delay_ms == 5000
      assert job.repeat_interval_ms == nil
      assert job.status == :queued
      assert job.current_attempt == 0
      assert job.last_error == nil
      assert %DateTime{} = job.scheduled_at
      assert %DateTime{} = job.created_at
      assert %DateTime{} = job.updated_at
      assert is_binary(job.id)
    end

    test "creates a job with custom scheduled_at" do
      custom_time = DateTime.add(DateTime.utc_now(), 3600, :second)
      attrs = %{module: TestJobModule, scheduled_at: custom_time}
      job = Job.new(attrs)

      assert job.scheduled_at == custom_time
    end

    test "generates unique IDs" do
      job1 = Job.new(%{module: TestJobModule})
      job2 = Job.new(%{module: TestJobModule})

      assert job1.id != job2.id
      assert is_binary(job1.id)
      assert is_binary(job2.id)
    end
  end

  describe "update/2" do
    test "updates job with new attributes" do
      job = Job.new(%{module: TestJobModule})

      updates = %{
        status: :processing,
        current_attempt: 2,
        last_error: "Some error"
      }

      updated_job = Job.update(job, updates)

      assert updated_job.id == job.id
      assert updated_job.module == job.module
      assert updated_job.status == :processing
      assert updated_job.current_attempt == 2
      assert updated_job.last_error == "Some error"
      assert DateTime.compare(updated_job.updated_at, job.updated_at) == :gt
    end

    test "automatically updates updated_at timestamp" do
      job = Job.new(%{module: TestJobModule})
      Process.sleep(1)

      updated_job = Job.update(job, %{status: :processing})

      assert DateTime.compare(updated_job.updated_at, job.updated_at) == :gt
    end

    test "handles empty updates" do
      job = Job.new(%{module: TestJobModule})

      updated_job = Job.update(job, %{})

      assert updated_job.module == job.module
      assert updated_job.status == job.status
      assert DateTime.compare(updated_job.updated_at, job.updated_at) == :gt
    end
  end

  describe "job status values" do
    test "supports all expected status values" do
      job = Job.new(%{module: TestJobModule})

      for status <- [:queued, :processing, :done, :failed] do
        updated_job = Job.update(job, %{status: status})
        assert updated_job.status == status
      end
    end
  end

  describe "id generation" do
    test "generates lowercase hexadecimal string" do
      job = Job.new(%{module: TestJobModule})

      assert String.match?(job.id, ~r/^[0-9a-f]+$/)
    end

    test "generates cryptographically strong random IDs" do
      ids = for _ <- 1..1000, do: Job.new(%{module: TestJobModule}).id

      # All IDs should be unique
      assert length(Enum.uniq(ids)) == 1000

      # All IDs should be 32 characters long (16 bytes in hex)
      assert Enum.all?(ids, &(String.length(&1) == 32))
    end
  end
end
