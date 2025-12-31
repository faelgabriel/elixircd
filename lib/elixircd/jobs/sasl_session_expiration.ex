defmodule ElixIRCd.Jobs.SaslSessionExpiration do
  @moduledoc """
  Job for automatically expiring SASL authentication sessions that have exceeded
  the configured timeout. Executes as part of the centralized JobQueue system.

  This job periodically checks for SASL sessions that have been active for too long
  and cleans them up, sending appropriate timeout messages to the clients.
  """

  @behaviour ElixIRCd.Jobs.JobBehavior

  require Logger

  alias ElixIRCd.JobQueue
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.SaslSessions
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.Job

  # Check every 30 seconds
  @check_interval 30_000

  @impl true
  @spec schedule() :: Job.t()
  def schedule do
    first_run_at = DateTime.add(DateTime.utc_now(), @check_interval, :millisecond)

    JobQueue.enqueue(__MODULE__, %{},
      scheduled_at: first_run_at,
      max_attempts: 3,
      retry_delay_ms: 5_000,
      repeat_interval_ms: @check_interval
    )
  end

  @impl true
  @spec run(Job.t()) :: :ok
  def run(_job) do
    expired_count = check_and_cleanup_expired_sessions()

    if expired_count > 0 do
      Logger.debug("Cleaned up #{expired_count} expired SASL session(s)")
    end

    :ok
  end

  @spec check_and_cleanup_expired_sessions() :: integer()
  defp check_and_cleanup_expired_sessions do
    sasl_config = Application.get_env(:elixircd, :sasl, [])
    timeout_ms = Keyword.get(sasl_config, :session_timeout_ms, 60_000)
    cutoff_time = DateTime.add(DateTime.utc_now(), -timeout_ms, :millisecond)

    Memento.transaction!(fn ->
      expired_sessions =
        ElixIRCd.Tables.SaslSession
        |> Memento.Query.all()
        |> Enum.filter(fn session ->
          DateTime.compare(session.created_at, cutoff_time) == :lt
        end)

      Enum.each(expired_sessions, &cleanup_expired_session/1)
      length(expired_sessions)
    end)
  end

  @spec cleanup_expired_session(ElixIRCd.Tables.SaslSession.t()) :: :ok
  defp cleanup_expired_session(session) do
    Logger.debug("SASL session timeout for user PID #{inspect(session.user_pid)}")

    case Users.get_by_pid(session.user_pid) do
      {:ok, user} ->
        %Message{
          command: :err_saslaborted,
          params: [user.nick || "*"],
          trailing: "SASL authentication timeout"
        }
        |> Dispatcher.broadcast(:server, user)

      _ ->
        :ok
    end

    SaslSessions.delete(session.user_pid)
  end
end
