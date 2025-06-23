defmodule ElixIRCd.Repositories.Jobs do
  @moduledoc """
  Repository module for managing jobs in Mnesia database.
  """

  alias ElixIRCd.Tables.Job

  @doc """
  Create a new job and write it to the database.
  """
  @spec create(map()) :: Job.t()
  def create(params) do
    Job.new(params)
    |> Memento.Query.write()
  end

  @doc """
  Get a job by ID.
  """
  @spec get_by_id(String.t()) :: {:ok, Job.t()} | {:error, :job_not_found}
  def get_by_id(id) do
    case Memento.Query.read(Job, id) do
      nil -> {:error, :job_not_found}
      job -> {:ok, job}
    end
  end

  @doc """
  Get all jobs with a specific status.
  """
  @spec get_by_status(atom()) :: [Job.t()]
  def get_by_status(status) do
    Job
    |> Memento.Query.all()
    |> Enum.filter(&(&1.status == status))
  end

  @doc """
  Get all jobs ready for execution (queued and scheduled_at <= now).
  """
  @spec get_ready_jobs() :: [Job.t()]
  def get_ready_jobs do
    now = DateTime.utc_now()

    Job
    |> Memento.Query.all()
    |> Enum.filter(&ready_for_execution?(&1, now))
    |> Enum.sort_by(&DateTime.to_unix(&1.scheduled_at))
  end

  @doc """
  Get all jobs.
  """
  @spec get_all() :: [Job.t()]
  def get_all, do: Memento.Query.all(Job)

  @doc """
  Update a job in the database.
  """
  @spec update(Job.t(), map()) :: Job.t()
  def update(job, attrs) do
    Job.update(job, attrs)
    |> Memento.Query.write()
  end

  @doc """
  Delete a job from the database.
  """
  @spec delete(Job.t()) :: :ok
  def delete(job), do: Memento.Query.delete_record(job)

  @doc """
  Delete all jobs with :done or :failed status older than the specified number of days.
  """
  @spec cleanup_old_jobs(pos_integer()) :: non_neg_integer()
  def cleanup_old_jobs(days_to_keep \\ 7) do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days_to_keep, :day)

    old_jobs =
      Job
      |> Memento.Query.all()
      |> Enum.filter(&old_completed_job?(&1, cutoff_date))

    Enum.each(old_jobs, &delete/1)
    length(old_jobs)
  end

  @spec ready_for_execution?(Job.t(), DateTime.t()) :: boolean()
  defp ready_for_execution?(job, now) do
    job.status == :queued and DateTime.compare(job.scheduled_at, now) != :gt
  end

  @spec old_completed_job?(Job.t(), DateTime.t()) :: boolean()
  defp old_completed_job?(job, cutoff_date) do
    job.status in [:done, :failed] and DateTime.compare(job.updated_at, cutoff_date) == :lt
  end
end
