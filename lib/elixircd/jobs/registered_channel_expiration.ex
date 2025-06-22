defmodule ElixIRCd.Jobs.RegisteredChannelExpiration do
  @moduledoc """
  Job for automatically expiring registered channels that have not been used for a configured
  period of time. Executes as part of the centralized JobQueue system.
  """

  @behaviour ElixIRCd.Jobs.JobBehavior

  require Logger

  alias ElixIRCd.JobQueue
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Tables.Job
  alias ElixIRCd.Tables.RegisteredChannel

  @first_cleanup_interval 2 * 60 * 60 * 1000
  @cleanup_interval 24 * 60 * 60 * 1000

  @impl true
  @spec schedule() :: Job.t()
  def schedule do
    first_run_at = DateTime.add(DateTime.utc_now(), @first_cleanup_interval, :millisecond)

    JobQueue.enqueue(
      __MODULE__,
      %{},
      scheduled_at: first_run_at,
      max_attempts: 3,
      retry_delay_ms: 30_000,
      repeat_interval_ms: @cleanup_interval
    )
  end

  @impl true
  @spec run(Job.t()) :: :ok
  def run(_job) do
    Logger.info("Starting expiration of unused channels")
    expired_count = expire_old_channels()
    Logger.info("Channel expiration completed. #{expired_count} channels were removed.")
    :ok
  end

  @spec expire_old_channels() :: integer()
  defp expire_old_channels do
    Memento.transaction!(fn ->
      RegisteredChannels.get_all()
      |> Enum.filter(&check_channel_expiration/1)
      |> Enum.map(&remove_expired_channel/1)
      |> length()
    end)
  end

  @spec remove_expired_channel(RegisteredChannel.t()) :: String.t()
  defp remove_expired_channel(registered_channel) do
    channel_name = registered_channel.name
    last_used_at = registered_channel.last_used_at || registered_channel.created_at
    Logger.info("Expiring channel: #{channel_name} (last used: #{last_used_at})")

    RegisteredChannels.delete(registered_channel)
    registered_channel.name
  end

  @spec check_channel_expiration(RegisteredChannel.t()) :: boolean()
  defp check_channel_expiration(registered_channel) do
    channel_expire_days = get_channel_expire_days()
    reference_date = registered_channel.last_used_at || registered_channel.created_at
    expiration_date = DateTime.add(reference_date, channel_expire_days, :day)

    DateTime.compare(DateTime.utc_now(), expiration_date) == :gt
  end

  @spec get_channel_expire_days() :: pos_integer()
  defp get_channel_expire_days do
    Application.get_env(:elixircd, :services)[:chanserv][:channel_expire_days] || 90
  end
end
