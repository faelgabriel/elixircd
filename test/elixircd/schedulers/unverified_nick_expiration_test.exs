defmodule ElixIRCd.Schedulers.UnverifiedNickExpirationTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Schedulers.UnverifiedNickExpiration
  alias ElixIRCd.Repositories.RegisteredNicks

  describe "handles unverified nick expiration cleanup" do
    setup do
      current_time = DateTime.utc_now()
      unverified_expire_days = Application.get_env(:elixircd, :services)[:nickserv][:unverified_expire_days] || 1

      # Verified nick - should not be removed
      verified_nick =
        insert(:registered_nick, %{nickname: "verified_nick", verify_code: nil, verified_at: current_time})

      # Unverified but not expired nick
      unexpired_nick =
        insert(:registered_nick, %{
          nickname: "unexpired_nick",
          verify_code: "code123",
          verified_at: nil,
          created_at: current_time
        })

      # Expired unverified nick - make the date older than expiration period (in seconds)
      expired_seconds = unverified_expire_days * 24 * 60 * 60 + 100
      expired_time = DateTime.add(current_time, -expired_seconds, :second)

      expired_nick =
        insert(:registered_nick, %{
          nickname: "expired_nick",
          verify_code: "code456",
          verified_at: nil,
          created_at: expired_time
        })

      {:ok, %{verified_nick: verified_nick, unexpired_nick: unexpired_nick, expired_nick: expired_nick}}
    end

    test "removes only expired unverified nicknames", %{
      verified_nick: verified_nick,
      unexpired_nick: unexpired_nick,
      expired_nick: expired_nick
    } do
      {:ok, pid} =
        GenServer.start_link(UnverifiedNickExpiration, %{last_cleanup: nil}, name: :test_unverified_expiration)

      send(pid, :cleanup)
      Process.sleep(100)

      Memento.transaction!(fn ->
        assert {:ok, _registered_nick} = RegisteredNicks.get_by_nickname(verified_nick.nickname)
        assert {:ok, _registered_nick} = RegisteredNicks.get_by_nickname(unexpired_nick.nickname)
        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname(expired_nick.nickname)
      end)
    end
  end
end
