defmodule ElixIRCd.Jobs.RegisteredNickExpiration do
  @moduledoc """
  Job for automatically expiring registered nicknames that have not been used for a configured
  period of time. Executes as part of the centralized JobQueue system.
  """

  @behaviour ElixIRCd.Jobs.JobBehavior

  require Logger

  import ElixIRCd.Utils.Nickserv,
    only: [cleanup_channel_registrations: 1, get_account_nick: 1, grouped?: 1, logout_account_users: 1]

  alias ElixIRCd.JobQueue
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.Memos
  alias ElixIRCd.Repositories.NickAccesses
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.Job
  alias ElixIRCd.Tables.RegisteredNick

  @first_cleanup_interval 1 * 60 * 60 * 1000
  @cleanup_interval 24 * 60 * 60 * 1000

  @impl true
  @spec schedule() :: Job.t()
  def schedule do
    first_run_at = DateTime.add(DateTime.utc_now(), @first_cleanup_interval, :millisecond)

    JobQueue.enqueue(__MODULE__, %{},
      scheduled_at: first_run_at,
      max_attempts: 3,
      retry_delay_ms: 30_000,
      repeat_interval_ms: @cleanup_interval
    )
  end

  @impl true
  @spec run(Job.t()) :: :ok
  def run(_job) do
    Logger.info("Starting expiration of unused nicknames")
    expired_count = expire_old_nicknames()
    Logger.info("Expiration completed. #{expired_count} nicknames were removed.")
    :ok
  end

  @spec expire_old_nicknames() :: integer()
  defp expire_old_nicknames do
    Observability.transaction(fn ->
      RegisteredNicks.get_all()
      |> Enum.filter(&check_nick_expiration/1)
      |> Enum.flat_map(&collect_nicks_to_expire/1)
      |> Enum.uniq_by(& &1.nickname_key)
      |> Enum.map(&remove_expired_nick/1)
      |> length()
    end)
  end

  @spec collect_nicks_to_expire(RegisteredNick.t()) :: [RegisteredNick.t()]
  defp collect_nicks_to_expire(registered_nick) do
    if registered_nick.nickname_key == registered_nick.account_name_key do
      RegisteredNicks.get_by_account_name(registered_nick.account_name)
    else
      [registered_nick]
    end
  end

  @spec remove_expired_nick(RegisteredNick.t()) :: String.t()
  defp remove_expired_nick(registered_nick) do
    Logger.debug("Expiring nickname", event: "account.nickname_expiring")

    if !grouped?(registered_nick) do
      logout_account_users(registered_nick.account_name)
      NickAccesses.delete_by_account_name(registered_nick.account_name)
      Memos.delete_by_recipient(registered_nick.account_name)
      cleanup_channel_registrations(registered_nick.account_name)
    end

    RegisteredNicks.delete(registered_nick)
    registered_nick.nickname
  end

  @spec check_nick_expiration(RegisteredNick.t()) :: boolean()
  defp check_nick_expiration(registered_nick) do
    nick_expire_days = get_nick_expire_days()

    reference_nick =
      if grouped?(registered_nick) do
        case get_account_nick(registered_nick) do
          {:ok, primary} -> primary
          {:error, :registered_nick_not_found} -> registered_nick
        end
      else
        registered_nick
      end

    reference_date = reference_nick.last_seen_at || reference_nick.created_at
    expiration_date = DateTime.add(reference_date, nick_expire_days, :day)

    DateTime.compare(DateTime.utc_now(), expiration_date) == :gt
  end

  @spec get_nick_expire_days() :: pos_integer()
  defp get_nick_expire_days do
    Application.fetch_env!(:elixircd, :services)[:nickserv][:nick_expire_days]
  end
end
