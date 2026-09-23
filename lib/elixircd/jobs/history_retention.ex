defmodule ElixIRCd.Jobs.HistoryRetention do
  @moduledoc "Periodically removes expired chat history and abandoned anonymous read markers."

  @behaviour ElixIRCd.Jobs.JobBehavior

  alias ElixIRCd.History
  alias ElixIRCd.JobQueue
  alias ElixIRCd.Repositories.ReadMarkers
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.Job

  @interval_ms 3_600_000

  @impl true
  @spec schedule() :: Job.t()
  def schedule do
    JobQueue.enqueue(__MODULE__, %{},
      scheduled_at: DateTime.add(DateTime.utc_now(), @interval_ms, :millisecond),
      max_attempts: 3,
      retry_delay_ms: 30_000,
      repeat_interval_ms: @interval_ms
    )
  end

  @impl true
  @spec run(Job.t()) :: :ok
  def run(_job) do
    History.prune_expired()

    Memento.transaction!(fn ->
      active_sessions =
        Users.get_all()
        |> Enum.filter(&is_nil(&1.identified_as))
        |> Enum.map(&History.identity_key/1)
        |> Enum.filter(&is_binary/1)
        |> MapSet.new()

      ReadMarkers.prune_abandoned_sessions(DateTime.add(DateTime.utc_now(), -86_400, :second), active_sessions)
    end)

    :ok
  end
end
