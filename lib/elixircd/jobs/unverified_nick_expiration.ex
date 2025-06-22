defmodule ElixIRCd.Jobs.UnverifiedNickExpiration do
  @moduledoc """
  Job for automatically expiring unverified nickname registrations after a configured
  period of time. Executes as part of the centralized JobQueue system.
  """

  @behaviour ElixIRCd.Jobs.JobBehavior

  require Logger

  alias ElixIRCd.JobQueue
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.Job
  alias ElixIRCd.Tables.RegisteredNick

  @first_cleanup_interval 30 * 60 * 1000
  @cleanup_interval 6 * 60 * 60 * 1000

  @impl true
  @spec type() :: atom()
  def type, do: :unverified_nick_expiration

  @impl true
  @spec enqueue() :: Job.t()
  def enqueue do
    first_run_at = DateTime.add(DateTime.utc_now(), @first_cleanup_interval, :millisecond)

    JobQueue.enqueue(
      :unverified_nick_expiration,
      %{},
      scheduled_at: first_run_at,
      max_attempts: 3,
      retry_delay_ms: 30_000,
      repeat_interval_ms: @cleanup_interval
    )
  end

  @impl true
  @spec run() :: :ok
  def run do
    Logger.info("Starting expiration of unverified nicknames")
    expired_count = expire_unverified_nicknames()
    Logger.info("Unverified nickname expiration completed. #{expired_count} nicknames were removed.")
    :ok
  end

  @spec expire_unverified_nicknames() :: integer()
  defp expire_unverified_nicknames do
    Memento.transaction!(fn ->
      RegisteredNicks.get_all()
      |> Enum.filter(&check_unverified_nick_expiration/1)
      |> Enum.map(&remove_expired_nick/1)
      |> length()
    end)
  end

  @spec remove_expired_nick(RegisteredNick.t()) :: String.t()
  defp remove_expired_nick(registered_nick) do
    nickname = registered_nick.nickname
    created_at = registered_nick.created_at
    Logger.info("Expiring unverified nickname: #{nickname} (registered: #{created_at})")

    RegisteredNicks.delete(registered_nick)
    registered_nick.nickname
  end

  @spec check_unverified_nick_expiration(RegisteredNick.t()) :: boolean()
  defp check_unverified_nick_expiration(registered_nick) do
    if unverified_nick?(registered_nick) do
      unverified_expire_seconds = get_unverified_expire_seconds()
      expiration_date = DateTime.add(registered_nick.created_at, unverified_expire_seconds, :second)
      DateTime.compare(DateTime.utc_now(), expiration_date) == :gt
    else
      false
    end
  end

  @spec unverified_nick?(RegisteredNick.t()) :: boolean()
  defp unverified_nick?(registered_nick) do
    not is_nil(registered_nick.verify_code) and is_nil(registered_nick.verified_at)
  end

  @spec get_unverified_expire_seconds() :: pos_integer()
  defp get_unverified_expire_seconds do
    unverified_expire_days = Application.get_env(:elixircd, :services)[:nickserv][:unverified_expire_days] || 1
    unverified_expire_days * 24 * 60 * 60
  end
end
