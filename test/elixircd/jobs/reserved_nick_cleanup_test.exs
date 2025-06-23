defmodule ElixIRCd.Jobs.ReservedNickCleanupTest do
  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Jobs.ReservedNickCleanup
  alias ElixIRCd.Repositories.RegisteredNicks

  describe "handles reserved nickname cleanup" do
    test "clears expired reservations but leaves active ones" do
      current_time = DateTime.utc_now()
      reserved_expire_seconds = Application.get_env(:elixircd, :services)[:nickserv][:reserved_expire_seconds] || 30
      future_time = DateTime.add(current_time, reserved_expire_seconds + 10, :second)
      active_reserved_nick = insert(:registered_nick, %{nickname: "active_reserved", reserved_until: future_time})
      expired_time = DateTime.add(current_time, -(reserved_expire_seconds + 10), :second)
      expired_reserved_nick = insert(:registered_nick, %{nickname: "expired_reserved", reserved_until: expired_time})
      unreserved_nick = insert(:registered_nick, %{nickname: "unreserved", reserved_until: nil})
      job = build(:job)

      assert :ok = ReservedNickCleanup.run(job)

      Memento.transaction!(fn ->
        {:ok, updated_active} = RegisteredNicks.get_by_nickname(active_reserved_nick.nickname)
        assert updated_active.reserved_until != nil

        {:ok, updated_expired} = RegisteredNicks.get_by_nickname(expired_reserved_nick.nickname)
        assert updated_expired.reserved_until == nil

        {:ok, updated_unreserved} = RegisteredNicks.get_by_nickname(unreserved_nick.nickname)
        assert updated_unreserved.reserved_until == nil
      end)
    end

    test "runs cleanup when no expired reservations found" do
      current_time = DateTime.utc_now()
      future_time = DateTime.add(current_time, 3600, :second)
      insert(:registered_nick, %{nickname: "active_reserved", reserved_until: future_time})
      insert(:registered_nick, %{nickname: "unreserved", reserved_until: nil})
      job = build(:job)

      assert :ok = ReservedNickCleanup.run(job)

      Memento.transaction!(fn ->
        {:ok, active_nick} = RegisteredNicks.get_by_nickname("active_reserved")
        assert active_nick.reserved_until != nil

        {:ok, unreserved_nick} = RegisteredNicks.get_by_nickname("unreserved")
        assert unreserved_nick.reserved_until == nil
      end)
    end

    test "schedule creates a job with correct parameters" do
      job = ReservedNickCleanup.schedule()

      assert job.module == ReservedNickCleanup
      assert job.status == :queued
      assert job.max_attempts == 3
      assert job.retry_delay_ms == 15_000
      assert job.repeat_interval_ms == 10 * 60 * 1000
      assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
    end
  end
end
