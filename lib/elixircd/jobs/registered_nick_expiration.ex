defmodule ElixIRCd.Jobs.RegisteredNickExpiration do
  @moduledoc """
  Job for automatically expiring registered nicknames that have not been used for a configured
  period of time. Executes as part of the centralized JobQueue system.
  """

  @behaviour ElixIRCd.Jobs.JobBehavior

  require Logger

  alias ElixIRCd.JobQueue
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.Job
  alias ElixIRCd.Tables.RegisteredNick

  @first_cleanup_interval 1 * 60 * 60 * 1000
  @cleanup_interval 24 * 60 * 60 * 1000

  @impl true
  @spec enqueue() :: Job.t()
  def enqueue do
    first_run_at = DateTime.add(DateTime.utc_now(), @first_cleanup_interval, :millisecond)

    JobQueue.enqueue(
      :registered_nick_expiration,
      %{},
      scheduled_at: first_run_at,
      max_attempts: 3,
      retry_delay_ms: 30_000,
      repeat_interval_ms: @cleanup_interval
    )
  end

  @impl true
  @spec type() :: atom()
  def type, do: :registered_nick_expiration

  @impl true
  @spec run() :: :ok
  def run do
    Memento.transaction!(fn ->
      Logger.info("Starting expiration of unused nicknames")
      expired_count = expire_old_nicknames()
      Logger.info("Expiration completed. #{expired_count} nicknames were removed.")

      :ok
    end)
  end

  @spec expire_old_nicknames() :: integer()
  defp expire_old_nicknames do
    RegisteredNicks.get_all()
    |> Enum.filter(&check_nick_expiration/1)
    |> Enum.map(&remove_expired_nick/1)
    |> length()
  end

  @spec remove_expired_nick(RegisteredNick.t()) :: String.t()
  defp remove_expired_nick(registered_nick) do
    nickname = registered_nick.nickname
    last_seen_at = registered_nick.last_seen_at || registered_nick.created_at
    Logger.info("Expiring nickname: #{nickname} (last seen: #{last_seen_at})")

    RegisteredNicks.delete(registered_nick)
    registered_nick.nickname
  end

  @spec check_nick_expiration(RegisteredNick.t()) :: boolean()
  defp check_nick_expiration(registered_nick) do
    nick_expire_days = get_nick_expire_days()
    reference_date = registered_nick.last_seen_at || registered_nick.created_at
    expiration_date = DateTime.add(reference_date, nick_expire_days, :day)

    DateTime.compare(DateTime.utc_now(), expiration_date) == :gt
  end

  @spec get_nick_expire_days() :: pos_integer()
  defp get_nick_expire_days do
    Application.get_env(:elixircd, :services)[:nickserv][:nick_expire_days] || 90
  end
end
