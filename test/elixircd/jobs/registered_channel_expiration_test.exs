defmodule ElixIRCd.Jobs.RegisteredChannelExpirationTest do
  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Jobs.RegisteredChannelExpiration
  alias ElixIRCd.Repositories.RegisteredChannels

  describe "handles registered channel expiration cleanup" do
    setup do
      current_time = DateTime.utc_now()
      channel_expire_days = Application.get_env(:elixircd, :services)[:chanserv][:channel_expire_days] || 90

      active_channel = insert(:registered_channel, %{name: "#active_channel", last_used_at: current_time})

      expired_time = DateTime.add(current_time, -(channel_expire_days + 1), :day)
      expired_channel = insert(:registered_channel, %{name: "#expired_channel", last_used_at: expired_time})

      old_created_time = DateTime.add(current_time, -(channel_expire_days + 1), :day)

      old_channel =
        insert(:registered_channel, %{name: "#old_channel", last_used_at: nil, created_at: old_created_time})

      job = build(:job)

      {:ok, %{active_channel: active_channel, expired_channel: expired_channel, old_channel: old_channel, job: job}}
    end

    test "removes expired channels", %{
      active_channel: active_channel,
      expired_channel: expired_channel,
      old_channel: old_channel,
      job: job
    } do
      RegisteredChannelExpiration.run(job)

      Memento.transaction!(fn ->
        assert {:ok, _registered_channel} = RegisteredChannels.get_by_name(active_channel.name)
        assert {:error, :registered_channel_not_found} = RegisteredChannels.get_by_name(expired_channel.name)
        assert {:error, :registered_channel_not_found} = RegisteredChannels.get_by_name(old_channel.name)
      end)
    end

    test "schedule creates a job with correct parameters" do
      job = RegisteredChannelExpiration.schedule()

      assert job.module == RegisteredChannelExpiration
      assert job.status == :queued
      assert job.max_attempts == 3
      assert job.retry_delay_ms == 30_000
      assert job.repeat_interval_ms == 24 * 60 * 60 * 1000
      assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
    end

    test "does not remove recently created channels", %{job: job} do
      current_time = DateTime.utc_now()

      recent_channel =
        insert(:registered_channel, %{name: "#recent_channel", created_at: current_time, last_used_at: current_time})

      RegisteredChannelExpiration.run(job)

      Memento.transaction!(fn ->
        assert {:ok, _registered_channel} = RegisteredChannels.get_by_name(recent_channel.name)
      end)
    end

    test "removes channel that has been unused since creation for long time", %{job: job} do
      current_time = DateTime.utc_now()
      channel_expire_days = Application.get_env(:elixircd, :services)[:chanserv][:channel_expire_days] || 90

      old_time = DateTime.add(current_time, -(channel_expire_days + 5), :day)

      unused_old_channel =
        insert(:registered_channel, %{
          name: "#unused_old_channel",
          created_at: old_time,
          last_used_at: old_time
        })

      RegisteredChannelExpiration.run(job)

      Memento.transaction!(fn ->
        assert {:error, :registered_channel_not_found} = RegisteredChannels.get_by_name(unused_old_channel.name)
      end)
    end
  end
end
