defmodule ElixIRCd.Jobs.JobBehavior do
  @moduledoc """
  Behavior for job modules in the ElixIRCd job queue system.

  Job modules implementing this behavior should define:
  - `enqueue/0` - Called once at application startup to schedule the initial job
  - `run/0` - The main job execution logic
  - `type/0` - Returns the job type atom for this job module
  """

  alias ElixIRCd.Tables.Job

  @doc """
  Enqueues the initial job for this job type.
  This is called once at application startup.
  """
  @callback enqueue() :: Job.t()

  @doc """
  Executes the main job logic.
  This is called by the JobQueue system when the job is ready to run.
  """
  @callback run() :: :ok | {:error, term()}

  @doc """
  Returns the job type atom for this job module.
  This is used internally by the JobQueue system.
  """
  @callback type() :: atom()

  @optional_callbacks [enqueue: 0]
end
