defmodule ElixIRCd.Server.NickEnforcementTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.NickEnforcement
  alias ElixIRCd.Tables.RegisteredNick.Settings

  test "replacing a timer prevents the earlier expiry from enforcing the nickname" do
    {registered_nick, user} =
      Memento.transaction!(fn ->
        registered_nick =
          insert(:registered_nick,
            nickname: "ProtectedNick",
            settings: Settings.new(%{enforce: true, enforce_time: 2, kill: :off})
          )

        deadline_at = DateTime.add(DateTime.utc_now(), 2, :second)

        user =
          insert(:user,
            nick: registered_nick.nickname,
            nick_enforcement_key: registered_nick.nickname_key,
            nick_enforcement_deadline_at: deadline_at
          )

        {registered_nick, user}
      end)

    assert :ok = NickEnforcement.schedule(user.pid, registered_nick.nickname_key, 1)
    assert NickEnforcement.grace_active?(user.pid, registered_nick.nickname_key)

    Process.sleep(100)
    assert :ok = NickEnforcement.schedule(user.pid, registered_nick.nickname_key, 2)
    assert NickEnforcement.grace_active?(user.pid, registered_nick.nickname_key)

    Process.sleep(1_000)

    assert Memento.transaction!(fn ->
             {:ok, current_user} = Users.get_by_pid(user.pid)
             current_user.nick == registered_nick.nickname
           end)

    assert NickEnforcement.grace_active?(user.pid, registered_nick.nickname_key)

    assert_eventually(fn ->
      Memento.transaction!(fn ->
        {:ok, enforced_user} = Users.get_by_pid(user.pid)
        enforced_user.nick != registered_nick.nickname and String.starts_with?(enforced_user.nick, "Guest")
      end)
    end)
  end

  test "restores a persisted deadline after its supervised process restarts" do
    deadline_at = DateTime.add(DateTime.utc_now(), 60, :second)

    user =
      Memento.transaction!(fn ->
        insert(:user)

        insert(:user,
          nick_enforcement_key: "protected",
          nick_enforcement_deadline_at: deadline_at
        )
      end)

    old_pid = Process.whereis(NickEnforcement)
    monitor_ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^old_pid, :killed}

    assert is_pid(wait_for_restart(old_pid))
    assert_eventually(fn -> NickEnforcement.grace_active?(user.pid, "protected") end)

    assert Memento.transaction!(fn ->
             {:ok, restored_user} = Users.get_by_pid(user.pid)
             restored_user.nick_enforcement_deadline_at == deadline_at
           end)

    NickEnforcement.cancel(user.pid)
  end

  test "reconciles enforcement when the session account changes" do
    Memento.transaction!(fn ->
      protected =
        insert(:registered_nick,
          nickname: "ProtectedNick",
          settings: Settings.new(%{enforce: true, enforce_time: 3600, kill: :off})
        )

      other_account = insert(:registered_nick, nickname: "OtherAccount")
      user = insert(:user, nick: protected.nickname, identified_as: other_account.account_name)

      assert :ok = NickEnforcement.schedule_enforcement(user)
      assert NickEnforcement.grace_active?(user.pid, protected.nickname_key)

      owner_session = Users.update(user, %{identified_as: protected.account_name})
      assert :ok = NickEnforcement.schedule_enforcement(owner_session)
      refute NickEnforcement.grace_active?(user.pid, protected.nickname_key)

      {:ok, authorized_user} = Users.get_by_pid(user.pid)
      assert is_nil(authorized_user.nick_enforcement_key)
      assert is_nil(authorized_user.nick_enforcement_deadline_at)
    end)
  end

  test "applies zero-delay enforcement immediately" do
    Memento.transaction!(fn ->
      registered_nick =
        insert(:registered_nick,
          nickname: "ImmediateNick",
          settings: Settings.new(%{enforce: true, enforce_time: 0, kill: :off})
        )

      user = insert(:user, nick: registered_nick.nickname)

      assert :ok = NickEnforcement.schedule_enforcement(user)

      {:ok, renamed_user} = Users.get_by_pid(user.pid)
      assert String.starts_with?(renamed_user.nick, "Guest")
      refute renamed_user.nick == registered_nick.nickname
      assert is_nil(renamed_user.nick_enforcement_key)
      assert is_nil(renamed_user.nick_enforcement_deadline_at)
    end)
  end

  test "fails closed when the timer service is unavailable" do
    registered_nick =
      Memento.transaction!(fn ->
        insert(:registered_nick,
          nickname: "UnavailableTimerNick",
          settings: Settings.new(%{enforce: true, enforce_time: 60, kill: :off})
        )
      end)

    user = Memento.transaction!(fn -> insert(:user, nick: registered_nick.nickname) end)
    assert :ok = Supervisor.terminate_child(ElixIRCd, NickEnforcement)

    try do
      Memento.transaction!(fn ->
        assert :ok = NickEnforcement.schedule_enforcement(user)
        {:ok, renamed_user} = Users.get_by_pid(user.pid)
        assert String.starts_with?(renamed_user.nick, "Guest")
        assert is_nil(renamed_user.nick_enforcement_key)
        assert is_nil(renamed_user.nick_enforcement_deadline_at)
      end)
    after
      assert {:ok, _pid} = Supervisor.restart_child(ElixIRCd, NickEnforcement)
    end
  end

  test "disconnects an unauthorized holder when KILL ON enforcement expires" do
    Memento.transaction!(fn ->
      registered_nick =
        insert(:registered_nick,
          nickname: "ExpiredKillNick",
          settings: Settings.new(%{enforce: true, enforce_time: 60, kill: :on})
        )

      user = insert(:user, pid: self(), nick: registered_nick.nickname)
      assert :ok = NickEnforcement.enforce_expired(user.pid, registered_nick.nickname_key)
      assert_sent_message_contains(user.pid, ~r/433 .*ExpiredKillNick.*reserved and enforced/)
      assert_received {:disconnect, "Nickname ExpiredKillNick is reserved and enforced by NickServ"}
    end)
  end

  test "retries a generated guest nickname collision during immediate enforcement" do
    Memento.transaction!(fn ->
      registered_nick =
        insert(:registered_nick,
          nickname: "ImmediateRenameNick",
          settings: Settings.new(%{enforce: true, enforce_time: 0, kill: :off})
        )

      user = insert(:user, nick: registered_nick.nickname)

      stub(Users, :get_by_nick, fn candidate ->
        case Process.get(:guest_nick_lookup_count, 0) do
          0 ->
            Process.put(:guest_nick_lookup_count, 1)
            {:ok, user}

          _count ->
            Mimic.call_original(Users, :get_by_nick, [candidate])
        end
      end)

      assert :ok = NickEnforcement.enforce_expired(user.pid, registered_nick.nickname_key)
      {:ok, renamed_user} = Users.get_by_pid(user.pid)
      assert String.starts_with?(renamed_user.nick, "Guest")
      refute renamed_user.nick == registered_nick.nickname
    end)
  end

  test "does not force a user onto another registered guest nickname" do
    Memento.transaction!(fn ->
      registered_nick =
        insert(:registered_nick,
          nickname: "ImmediateRegisteredCollision",
          settings: Settings.new(%{enforce: true, enforce_time: 0, kill: :off})
        )

      user = insert(:user, nick: registered_nick.nickname)
      parent = self()

      stub(ElixIRCd.Repositories.RegisteredNicks, :get_by_nickname, fn nickname ->
        if String.starts_with?(nickname, "Guest") and Process.get(:registered_guest_collision, 0) == 0 do
          Process.put(:registered_guest_collision, 1)
          send(parent, {:collided_guest_nick, nickname})
          {:ok, registered_nick}
        else
          Mimic.call_original(ElixIRCd.Repositories.RegisteredNicks, :get_by_nickname, [nickname])
        end
      end)

      assert :ok = NickEnforcement.enforce_expired(user.pid, registered_nick.nickname_key)
      assert_received {:collided_guest_nick, collided_nick}

      {:ok, renamed_user} = Users.get_by_pid(user.pid)
      assert String.starts_with?(renamed_user.nick, "Guest")
      refute renamed_user.nick == collided_nick
    end)
  end

  test "rejects unsafe delays without crashing the supervised service" do
    max_delay = Application.fetch_env!(:elixircd, :services)[:nickserv][:max_enforce_time]
    enforcement_pid = Process.whereis(NickEnforcement)

    assert {:error, :invalid_delay} = NickEnforcement.schedule(self(), "protected", max_delay + 1)
    assert {:error, :invalid_delay} = NickEnforcement.schedule(self(), "protected", -1)
    assert Process.whereis(NickEnforcement) == enforcement_pid
  end

  test "survives a burst of already-due timer replacements through its public API" do
    timer_owner = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(timer_owner, :kill) end)

    Enum.each(1..100, fn _iteration ->
      assert :ok = NickEnforcement.schedule(timer_owner, "protected", 0)
      assert :ok = NickEnforcement.schedule(timer_owner, "protected", 60)
    end)

    assert_eventually(fn -> NickEnforcement.grace_active?(timer_owner, "protected") end)
    Process.sleep(50)
    assert NickEnforcement.grace_active?(timer_owner, "protected")

    NickEnforcement.cancel(timer_owner)
  end

  defp wait_for_restart(old_pid, attempts \\ 100)

  defp wait_for_restart(old_pid, attempts) when attempts > 0 do
    case Process.whereis(NickEnforcement) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _other ->
        Process.sleep(10)
        wait_for_restart(old_pid, attempts - 1)
    end
  end

  defp wait_for_restart(_old_pid, 0), do: flunk("nickname enforcement supervisor did not restart its child")

  defp assert_eventually(condition, attempts \\ 200)

  defp assert_eventually(condition, attempts) when attempts > 0 do
    if condition.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(condition, attempts - 1)
    end
  end

  defp assert_eventually(_condition, 0), do: flunk("condition did not become true before timeout")
end
