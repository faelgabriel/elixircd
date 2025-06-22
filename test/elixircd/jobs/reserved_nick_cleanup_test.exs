defmodule ElixIRCd.Jobs.ReservedNickCleanupTest do
  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Jobs.ReservedNickCleanup
  alias ElixIRCd.Repositories.RegisteredNicks

  describe "handles reserved nickname cleanup" do
    setup do
      future_time = DateTime.add(current_time, 3600, :second)
      past_time = DateTime.add(current_time, -300, :second)

      {:ok,
       %{
         future_time: future_time,
         past_time: past_time
       }}
    end

    test "enqueue creates a job with correct parameters" do
      job = ReservedNickCleanup.enqueue()

      assert job.type == :reserved_nick_cleanup
      assert job.status == :queued
      assert job.max_attempts == 3
      assert job.retry_delay_ms == 15_000
      assert job.repeat_interval_ms == 10 * 60 * 1000
      assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
    end

    test "returns correct job type" do
      assert ReservedNickCleanup.type() == :reserved_nick_cleanup
    end

    test "cleans up only expired reservations", %{future_time: future_time, past_time: past_time} do
      unreserved_nick = insert(:registered_nick, %{nickname: "unreserved_nick", reserved_until: nil})
      reserved_nick = insert(:registered_nick, %{nickname: "reserved_nick", reserved_until: future_time})
      expired_reserved_nick = insert(:registered_nick, %{nickname: "expired_reserved_nick", reserved_until: past_time})

      ReservedNickCleanup.run()

      Memento.transaction!(fn ->
        # Unreserved nick should remain unchanged
        {:ok, updated_unreserved} = RegisteredNicks.get_by_nickname(unreserved_nick.nickname)
        assert updated_unreserved.reserved_until == nil

        # Still reserved nick should remain reserved
        {:ok, updated_reserved} = RegisteredNicks.get_by_nickname(reserved_nick.nickname)
        assert updated_reserved.reserved_until != nil
        assert DateTime.compare(updated_reserved.reserved_until, DateTime.utc_now()) == :gt

        # Expired reserved nick should have reservation cleared
        {:ok, updated_expired} = RegisteredNicks.get_by_nickname(expired_reserved_nick.nickname)
        assert updated_expired.reserved_until == nil
      end)
    end

    test "handles multiple expired reservations", %{past_time: past_time} do
      expired_nick1 = insert(:registered_nick, %{nickname: "expired1", reserved_until: past_time})
      expired_nick2 = insert(:registered_nick, %{nickname: "expired2", reserved_until: past_time})
      expired_nick3 = insert(:registered_nick, %{nickname: "expired3", reserved_until: past_time})

      ReservedNickCleanup.run()

      Memento.transaction!(fn ->
        {:ok, updated1} = RegisteredNicks.get_by_nickname(expired_nick1.nickname)
        {:ok, updated2} = RegisteredNicks.get_by_nickname(expired_nick2.nickname)
        {:ok, updated3} = RegisteredNicks.get_by_nickname(expired_nick3.nickname)

        assert updated1.reserved_until == nil
        assert updated2.reserved_until == nil
        assert updated3.reserved_until == nil
      end)
    end

    test "handles no expired reservations gracefully", %{future_time: future_time} do
      reserved_nick1 = insert(:registered_nick, %{nickname: "reserved1", reserved_until: future_time})
      reserved_nick2 = insert(:registered_nick, %{nickname: "reserved2", reserved_until: future_time})

      ReservedNickCleanup.run()

      Memento.transaction!(fn ->
        {:ok, updated1} = RegisteredNicks.get_by_nickname(reserved_nick1.nickname)
        {:ok, updated2} = RegisteredNicks.get_by_nickname(reserved_nick2.nickname)

        assert updated1.reserved_until != nil
        assert updated2.reserved_until != nil
        assert DateTime.compare(updated1.reserved_until, DateTime.utc_now()) == :gt
        assert DateTime.compare(updated2.reserved_until, DateTime.utc_now()) == :gt
      end)
    end
  end
end
