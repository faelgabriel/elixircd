defmodule ElixIRCd.Schedulers.RegisteredNickExpirationTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Schedulers.RegisteredNickExpiration
  alias ElixIRCd.Repositories.RegisteredNicks

  describe "handles registered nick expiration cleanup" do
    setup do
      current_time = DateTime.utc_now()
      nick_expire_days = Application.get_env(:elixircd, :services)[:nickserv][:nick_expire_days] || 90

      # Active nick (recently seen)
      active_nick = insert(:registered_nick, %{nickname: "active_nick", last_seen_at: current_time})

      # Create an expired nick - make the date older than expiration period
      expired_time = DateTime.add(current_time, -(nick_expire_days + 1), :day)
      expired_nick = insert(:registered_nick, %{nickname: "expired_nick", last_seen_at: expired_time})

      # Create nick without last_seen_at but created before expiration period
      old_created_time = DateTime.add(current_time, -(nick_expire_days + 1), :day)
      old_nick = insert(:registered_nick, %{nickname: "old_nick", last_seen_at: nil, created_at: old_created_time})

      {:ok, %{active_nick: active_nick, expired_nick: expired_nick, old_nick: old_nick}}
    end

    test "removes expired nicknames", %{active_nick: active_nick, expired_nick: expired_nick, old_nick: old_nick} do
      {:ok, pid} = GenServer.start_link(RegisteredNickExpiration, %{last_cleanup: nil}, name: :test_nick_expiration)

      send(pid, :cleanup)
      Process.sleep(100)

      Memento.transaction!(fn ->
        assert {:ok, _registered_nick} = RegisteredNicks.get_by_nickname(active_nick.nickname)
        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname(expired_nick.nickname)
        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname(old_nick.nickname)
      end)
    end
  end
end
