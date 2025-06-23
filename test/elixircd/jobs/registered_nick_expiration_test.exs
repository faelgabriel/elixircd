defmodule ElixIRCd.Jobs.RegisteredNickExpirationTest do
  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Jobs.RegisteredNickExpiration
  alias ElixIRCd.Repositories.RegisteredNicks

  describe "handles registered nick expiration cleanup" do
    setup do
      current_time = DateTime.utc_now()
      nick_expire_days = Application.get_env(:elixircd, :services)[:nickserv][:nick_expire_days] || 90

      active_nick = insert(:registered_nick, %{nickname: "active_nick", last_seen_at: current_time})

      expired_time = DateTime.add(current_time, -(nick_expire_days + 1), :day)
      expired_nick = insert(:registered_nick, %{nickname: "expired_nick", last_seen_at: expired_time})

      old_created_time = DateTime.add(current_time, -(nick_expire_days + 1), :day)
      old_nick = insert(:registered_nick, %{nickname: "old_nick", last_seen_at: nil, created_at: old_created_time})

      job = build(:job)

      {:ok, %{active_nick: active_nick, expired_nick: expired_nick, old_nick: old_nick, job: job}}
    end

    test "removes expired nicknames", %{
      active_nick: active_nick,
      expired_nick: expired_nick,
      old_nick: old_nick,
      job: job
    } do
      RegisteredNickExpiration.run(job)

      Memento.transaction!(fn ->
        assert {:ok, _registered_nick} = RegisteredNicks.get_by_nickname(active_nick.nickname)
        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname(expired_nick.nickname)
        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname(old_nick.nickname)
      end)
    end

    test "schedule creates a job with correct parameters" do
      job = RegisteredNickExpiration.schedule()

      assert job.module == RegisteredNickExpiration
      assert job.status == :queued
      assert job.max_attempts == 3
      assert job.retry_delay_ms == 30_000
      assert job.repeat_interval_ms == 24 * 60 * 60 * 1000
      assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
    end
  end
end
