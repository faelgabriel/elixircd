defmodule ElixIRCd.Jobs.ReservedNickCleanup do
  @moduledoc """
  Job for automatically cleaning up expired nickname reservations.
  This job removes the reserved_until timestamp when the reservation period has expired,
  making the nickname available for use by others again.
  """

  @behaviour ElixIRCd.Jobs.JobBehavior

  require Logger

  alias ElixIRCd.JobQueue
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.Job
  alias ElixIRCd.Tables.RegisteredNick

  @first_cleanup_interval 5 * 60 * 1000
  @cleanup_interval 10 * 60 * 1000

  @impl true
  @spec schedule() :: Job.t()
  def schedule do
    first_run_at = DateTime.add(DateTime.utc_now(), @first_cleanup_interval, :millisecond)

    JobQueue.enqueue(
      __MODULE__,
      %{},
      scheduled_at: first_run_at,
      max_attempts: 3,
      retry_delay_ms: 15_000,
      repeat_interval_ms: @cleanup_interval
    )
  end

  @impl true
  @spec run(Job.t()) :: :ok
  def run(_job) do
    Logger.debug("Starting cleanup of expired nickname reservations")
    cleaned_count = cleanup_expired_reservations()

    if cleaned_count > 0 do
      Logger.info("Reserved nickname cleanup completed. #{cleaned_count} reservations were expired.")
    else
      Logger.debug("Reserved nickname cleanup completed. No expired reservations found.")
    end

    :ok
  end

  @spec cleanup_expired_reservations() :: integer()
  defp cleanup_expired_reservations do
    Memento.transaction!(fn ->
      RegisteredNicks.get_all()
      |> Enum.filter(&check_reservation_expiration/1)
      |> Enum.map(&clear_expired_reservation/1)
      |> length()
    end)
  end

  @spec clear_expired_reservation(RegisteredNick.t()) :: String.t()
  defp clear_expired_reservation(registered_nick) do
    nickname = registered_nick.nickname
    reserved_until = registered_nick.reserved_until
    Logger.debug("Clearing expired reservation for nickname: #{nickname} (was reserved until: #{reserved_until})")

    RegisteredNicks.update(registered_nick, %{reserved_until: nil})
    registered_nick.nickname
  end

  @spec check_reservation_expiration(RegisteredNick.t()) :: boolean()
  defp check_reservation_expiration(registered_nick) do
    case registered_nick.reserved_until do
      nil -> false
      reserved_until -> DateTime.compare(DateTime.utc_now(), reserved_until) == :gt
    end
  end
end
