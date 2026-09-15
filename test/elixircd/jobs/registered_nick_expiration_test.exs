defmodule ElixIRCd.Jobs.RegisteredNickExpirationTest do
  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Jobs.RegisteredNickExpiration
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users

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

    test "keeps grouped nick alive when primary nick is still active", %{job: job} do
      current_time = DateTime.utc_now()
      nick_expire_days = Application.get_env(:elixircd, :services)[:nickserv][:nick_expire_days] || 90

      active_primary = insert(:registered_nick, %{nickname: "ActivePrimary", last_seen_at: current_time})

      expired_time = DateTime.add(current_time, -(nick_expire_days + 1), :day)

      _grouped_alias =
        insert(:registered_nick, %{
          nickname: "AliasOfActive",
          account_name: active_primary.nickname,
          last_seen_at: expired_time
        })

      RegisteredNickExpiration.run(job)

      Memento.transaction!(fn ->
        assert {:ok, _} = RegisteredNicks.get_by_nickname("ActivePrimary")
        assert {:ok, _} = RegisteredNicks.get_by_nickname("AliasOfActive")
      end)
    end

    test "expires grouped nick when primary nick is also expired", %{job: job} do
      current_time = DateTime.utc_now()
      nick_expire_days = Application.get_env(:elixircd, :services)[:nickserv][:nick_expire_days] || 90
      expired_time = DateTime.add(current_time, -(nick_expire_days + 1), :day)

      expired_primary =
        insert(:registered_nick, %{nickname: "ExpiredPrimary", last_seen_at: expired_time})

      _grouped_alias =
        insert(:registered_nick, %{
          nickname: "AliasOfExpired",
          account_name: expired_primary.nickname,
          last_seen_at: current_time
        })

      RegisteredNickExpiration.run(job)

      Memento.transaction!(fn ->
        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname("ExpiredPrimary")
        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname("AliasOfExpired")
      end)
    end

    test "logs out online users identified to an expired account", %{job: job} do
      current_time = DateTime.utc_now()
      nick_expire_days = Application.get_env(:elixircd, :services)[:nickserv][:nick_expire_days] || 90
      expired_time = DateTime.add(current_time, -(nick_expire_days + 1), :day)

      expired_nick = insert(:registered_nick, %{nickname: "ExpiredAccount", last_seen_at: expired_time})

      user =
        insert(:user, %{
          nick: "SomeNick",
          identified_as: expired_nick.nickname,
          modes: [:r],
          sasl_authenticated: true
        })

      RegisteredNickExpiration.run(job)

      Memento.transaction!(fn ->
        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil
        assert updated_user.sasl_authenticated == false
        assert :r not in updated_user.modes
      end)
    end

    test "expires grouped nick when canonical account record is missing", %{job: job} do
      current_time = DateTime.utc_now()
      nick_expire_days = Application.get_env(:elixircd, :services)[:nickserv][:nick_expire_days] || 90
      expired_time = DateTime.add(current_time, -(nick_expire_days + 1), :day)

      insert(:registered_nick, %{
        nickname: "DanglingAlias",
        account_name: "MissingPrimary",
        last_seen_at: expired_time
      })

      RegisteredNickExpiration.run(job)

      Memento.transaction!(fn ->
        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname("DanglingAlias")
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
