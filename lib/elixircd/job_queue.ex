defmodule ElixIRCd.JobQueue do
  @moduledoc """
  A GenServer-based job queue system.
  """

  use GenServer

  require Logger

  alias ElixIRCd.Jobs.JobBehavior
  alias ElixIRCd.Repositories.Jobs
  alias ElixIRCd.Tables.Job

  @poll_interval 5_000
  @concurrent_jobs 1

  @doc """
  Starts the JobQueue GenServer.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Enqueue a new job.
  """
  @spec enqueue(module(), map(), [
          {:scheduled_at, DateTime.t()}
          | {:max_attempts, pos_integer()}
          | {:retry_delay_ms, pos_integer()}
          | {:repeat_interval_ms, pos_integer() | nil}
        ]) :: Job.t()
  def enqueue(job_module, payload \\ %{}, opts \\ []) do
    unless implements_job_behavior?(job_module) do
      raise ArgumentError, "Module #{job_module} does not implement ElixIRCd.Jobs.JobBehavior"
    end

    job_params = %{
      module: job_module,
      payload: payload,
      scheduled_at: Keyword.get(opts, :scheduled_at, DateTime.utc_now()),
      max_attempts: Keyword.get(opts, :max_attempts, 3),
      retry_delay_ms: Keyword.get(opts, :retry_delay_ms, 5000),
      repeat_interval_ms: Keyword.get(opts, :repeat_interval_ms)
    }

    job =
      Memento.transaction!(fn ->
        Jobs.create(job_params)
      end)

    Logger.info("Job enqueued: #{inspect(job.module)} (id: #{job.id})")
    job
  end

  @doc """
  Get job statistics.
  """
  @spec get_stats() :: map()
  def get_stats do
    Memento.transaction!(fn ->
      all_jobs = Jobs.get_all()

      %{
        total: length(all_jobs),
        queued: count_by_status(all_jobs, :queued),
        processing: count_by_status(all_jobs, :processing),
        done: count_by_status(all_jobs, :done),
        failed: count_by_status(all_jobs, :failed)
      }
    end)
  end

  @doc """
  Cancel a job by ID.
  """
  @spec cancel_job(String.t()) :: :ok | {:error, :job_not_found | :job_not_cancellable}
  def cancel_job(job_id) do
    Memento.transaction!(fn ->
      case Jobs.get_by_id(job_id) do
        {:ok, job} -> cancel_job_if_possible(job, job_id)
        error -> error
      end
    end)
  end

  @spec cancel_job_if_possible(Job.t(), String.t()) :: :ok | {:error, :job_not_cancellable}
  defp cancel_job_if_possible(job, job_id) do
    if job.status in [:queued, :processing] do
      Jobs.update(job, %{status: :failed, last_error: "Cancelled by admin"})
      Logger.info("Job cancelled: #{inspect(job.module)} (id: #{job_id})")
      :ok
    else
      Logger.warning("Cannot cancel job in status #{job.status}: #{inspect(job.module)} (id: #{job_id})")
      {:error, :job_not_cancellable}
    end
  end

  @doc """
  Retry a failed job.
  """
  @spec retry_job(String.t()) :: :ok | {:error, term()}
  def retry_job(job_id) do
    Memento.transaction!(fn ->
      case Jobs.get_by_id(job_id) do
        {:ok, job} -> retry_job_if_failed(job, job_id)
        error -> error
      end
    end)
  end

  @spec retry_job_if_failed(Job.t(), String.t()) :: :ok | {:error, :job_not_retryable}
  defp retry_job_if_failed(job, job_id) do
    if job.status == :failed do
      Jobs.update(job, %{
        status: :queued,
        current_attempt: 0,
        scheduled_at: DateTime.utc_now(),
        last_error: nil
      })

      Logger.info("Job retry scheduled: #{inspect(job.module)} (id: #{job_id})")
      :ok
    else
      Logger.warning("Cannot retry job in status #{job.status}: #{inspect(job.module)} (id: #{job_id})")
      {:error, :job_not_retryable}
    end
  end

  @doc """
  Get detailed statistics about the job queue.
  """
  @spec get_detailed_stats() :: map()
  def get_detailed_stats do
    Memento.transaction!(fn ->
      all_jobs = Jobs.get_all()
      now = DateTime.utc_now()

      stats = get_stats()

      overdue_jobs = count_overdue_jobs(all_jobs, now)
      jobs_by_type = group_jobs_by_type(all_jobs)
      recent_failures = count_recent_failures(all_jobs, now)

      Map.merge(stats, %{
        overdue: overdue_jobs,
        jobs_by_type: jobs_by_type,
        recent_failures_24h: recent_failures
      })
    end)
  end

  @doc """
  Clean up old completed jobs.
  """
  @spec cleanup_old_jobs(pos_integer()) :: integer()
  def cleanup_old_jobs(days_to_keep \\ 7) do
    Memento.transaction!(fn ->
      Jobs.cleanup_old_jobs(days_to_keep)
    end)
  end

  @doc """
  List jobs with optional filtering.
  """
  @spec list_jobs(keyword()) :: [Job.t()]
  def list_jobs(opts \\ []) do
    Memento.transaction!(fn ->
      Jobs.get_all()
      |> maybe_filter_by_status(opts[:status])
      |> maybe_filter_by_type(opts[:type])
      |> maybe_limit(opts[:limit])
    end)
  end

  @impl true
  @spec init(map()) :: {:ok, map()}
  def init(_state) do
    schedule_initial_jobs()
    send(self(), :recover_stuck_jobs)
    send(self(), :poll_jobs)
    {:ok, %{}}
  end

  @impl true
  @spec handle_info(any(), map()) :: {:noreply, map()}
  def handle_info(:poll_jobs, state) do
    process_ready_jobs()
    Process.send_after(self(), :poll_jobs, @poll_interval)
    {:noreply, state}
  end

  def handle_info(:recover_stuck_jobs, state) do
    recover_stuck_jobs()
    {:noreply, state}
  end

  @spec schedule_initial_jobs() :: :ok
  defp schedule_initial_jobs do
    discover_job_modules()
    |> Enum.each(fn module ->
      if function_exported?(module, :schedule, 0) do
        module.schedule()
      end
    end)
  end

  @spec discover_job_modules() :: [module()]
  defp discover_job_modules do
    {:ok, modules} = :application.get_key(:elixircd, :modules)
    Enum.filter(modules, &implements_job_behavior?/1)
  end

  @spec process_ready_jobs() :: :ok
  defp process_ready_jobs do
    ready_jobs = Memento.transaction!(fn -> Jobs.get_ready_jobs() end)

    ready_jobs
    |> Enum.take(@concurrent_jobs)
    |> Enum.each(&execute_job_process/1)

    :ok
  end

  @spec execute_job_process(Job.t()) :: :ok
  defp execute_job_process(job) do
    current_attempt = job.current_attempt + 1
    max_attempts = job.max_attempts
    Logger.info("Executing job: #{inspect(job.module)} (id: #{job.id}, attempt: #{current_attempt}/#{max_attempts})")

    updated_job =
      Memento.transaction!(fn ->
        Jobs.update(job, %{
          status: :processing,
          current_attempt: job.current_attempt + 1
        })
      end)

    result = updated_job.module.run(updated_job)

    Memento.transaction!(fn ->
      case result do
        :ok -> handle_job_success(updated_job)
        {:error, reason} -> handle_job_failure(updated_job, reason)
      end
    end)

    :ok
  end

  @spec implements_job_behavior?(module()) :: boolean()
  defp implements_job_behavior?(module) do
    behaviours = module.module_info(:attributes)[:behaviour] || []
    JobBehavior in behaviours
  end

  @spec handle_job_success(Job.t()) :: :ok
  defp handle_job_success(job) do
    Logger.info("Job completed successfully: #{job.id}")
    Jobs.update(job, %{status: :done, last_error: nil})

    if job.repeat_interval_ms do
      schedule_recurring_job(job)
    end

    :ok
  end

  @spec handle_job_failure(Job.t(), String.t()) :: :ok
  defp handle_job_failure(job, error_message) do
    Logger.error("Job failed: #{job.id} - #{error_message}")

    if job.current_attempt >= job.max_attempts do
      Jobs.update(job, %{
        status: :failed,
        last_error: error_message
      })

      Logger.error("Job permanently failed after #{job.max_attempts} attempts: #{job.id}")
    else
      retry_at = DateTime.add(DateTime.utc_now(), job.retry_delay_ms, :millisecond)

      Jobs.update(job, %{
        status: :queued,
        scheduled_at: retry_at,
        last_error: error_message
      })

      Logger.info("Job will be retried at #{retry_at}: #{job.id}")
    end

    :ok
  end

  @spec schedule_recurring_job(Job.t()) :: :ok
  defp schedule_recurring_job(job) do
    next_run_at = DateTime.add(DateTime.utc_now(), job.repeat_interval_ms, :millisecond)

    new_job_params = %{
      module: job.module,
      payload: job.payload,
      scheduled_at: next_run_at,
      max_attempts: job.max_attempts,
      retry_delay_ms: job.retry_delay_ms,
      repeat_interval_ms: job.repeat_interval_ms
    }

    Jobs.create(new_job_params)
    Logger.info("Recurring job scheduled for #{next_run_at}: #{inspect(job.module)}")

    :ok
  end

  @spec maybe_filter_by_status([Job.t()], atom() | nil) :: [Job.t()]
  defp maybe_filter_by_status(jobs, nil), do: jobs
  defp maybe_filter_by_status(jobs, status), do: Enum.filter(jobs, &(&1.status == status))

  @spec maybe_filter_by_type([Job.t()], module() | nil) :: [Job.t()]
  defp maybe_filter_by_type(jobs, nil), do: jobs
  defp maybe_filter_by_type(jobs, module), do: Enum.filter(jobs, &(&1.module == module))

  @spec maybe_limit([Job.t()], pos_integer() | nil) :: [Job.t()]
  defp maybe_limit(jobs, nil), do: jobs
  defp maybe_limit(jobs, limit), do: Enum.take(jobs, limit)

  defp count_by_status(jobs, status) do
    Enum.count(jobs, &(&1.status == status))
  end

  defp count_overdue_jobs(jobs, now) do
    Enum.count(jobs, fn job ->
      job.status == :queued and DateTime.compare(job.scheduled_at, now) == :lt
    end)
  end

  defp group_jobs_by_type(jobs) do
    jobs
    |> Enum.group_by(& &1.module)
    |> Enum.into(%{}, fn {module, jobs} -> {module, length(jobs)} end)
  end

  defp count_recent_failures(jobs, now) do
    jobs
    |> Enum.count(fn job ->
      job.status == :failed and
        DateTime.diff(now, job.updated_at, :hour) <= 24
    end)
  end

  @spec recover_stuck_jobs() :: :ok
  defp recover_stuck_jobs do
    Memento.transaction!(fn ->
      stuck_jobs = Jobs.get_by_status(:processing)

      Enum.each(stuck_jobs, fn job ->
        Logger.warning("Recovering stuck job from previous crash: #{inspect(job.module)} (id: #{job.id})")

        Jobs.update(job, %{
          status: :queued,
          scheduled_at: DateTime.add(DateTime.utc_now(), job.retry_delay_ms, :millisecond)
        })
      end)

      if length(stuck_jobs) > 0 do
        Logger.info("Recovered #{length(stuck_jobs)} stuck jobs")
      end
    end)

    :ok
  end
end
