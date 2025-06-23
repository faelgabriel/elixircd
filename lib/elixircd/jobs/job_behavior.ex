defmodule ElixIRCd.Jobs.JobBehavior do
  @moduledoc """
  Behavior for job modules in the ElixIRCd job queue system.

  Job modules implementing this behavior should define:
  - `schedule/0` - Called once at application startup to schedule the initial job for periodic jobs
  - `run/1` - The main job execution logic
  """

  alias ElixIRCd.Tables.Job

  @doc """
  Schedules the job.
  """
  @callback schedule() :: Job.t()

  @doc """
  Runs the job.
  """
  @callback run(Job.t()) :: :ok | {:error, term()}

  @optional_callbacks [schedule: 0]
end
