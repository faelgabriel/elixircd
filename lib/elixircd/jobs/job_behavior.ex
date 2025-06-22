defmodule ElixIRCd.Jobs.JobBehavior do
  @moduledoc """
  Behavior for job modules in the ElixIRCd job queue system.

  Job modules implementing this behavior should define:
  - `schedule/0` - Called once at application startup to schedule the initial job for periodic jobs
  - `run/1` - The main job execution logic
  """

  alias ElixIRCd.Tables.Job

  @doc """
  Schedules the initial job for this job type.
  This is called once at application startup for periodic jobs.
  """
  @callback schedule() :: Job.t()

  @doc """
  Executes the main job logic.
  This is called by the JobQueue system when the job is ready to run.
  The job struct contains all job information including payload, attempt count, etc.
  Should return :ok on success or {:error, reason} on failure.
  """
  @callback run(Job.t()) :: :ok | {:error, term()}

  @optional_callbacks [schedule: 0]
end
