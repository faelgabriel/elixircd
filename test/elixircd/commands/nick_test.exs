defmodule ElixIRCd.Commands.NickTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Nick
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Server.Handshake
  alias ElixIRCd.Server.NickEnforcement
  alias ElixIRCd.Tables.RegisteredNick.Settings

  describe "handle/2" do
    test "handles concurrent NICK commands for case-equivalent nicknames" do
      users = Memento.transaction!(fn -> [insert(:user), insert(:user)] end)
      parent = self()

      tasks =
        Enum.zip_with(users, ["Claim[", "cLAIM{"], fn user, nickname ->
          Task.async(fn ->
            Mimic.allow(Connection, parent, self())

            receive do
              :claim -> Memento.transaction!(fn -> Nick.handle(user, %Message{command: "NICK", params: [nickname]}) end)
            end
          end)
        end)

      Enum.each(tasks, &send(&1.pid, :claim))
      assert Task.await_many(tasks) == [:ok, :ok]

      Memento.transaction!(fn ->
        assert {:ok, winner} = Users.get_by_nick("Claim[")
        loser = Enum.find(users, &(&1.pid != winner.pid))
        assert Enum.count(Users.get_all(), &(&1.nick_key == winner.nick_key)) == 1
        assert {:ok, ^loser} = Users.get_by_pid(loser.pid)
        assert_sent_messages_count_containing(loser.pid, ~r/ 433 /, 1)
        assert_sent_messages_count_containing(winner.pid, ~r/ NICK /, 1)
      end)
    end

    test "handles NICK command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "NICK", params: []}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} NICK :Not enough parameters\r\n"}
        ])
      end)
    end

    test "blocks unprivileged nickname changes in +N channels" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "oldnick")
        channel = insert(:channel, name: "#stable", modes: [:N])
        insert(:user_channel, user: user, channel: channel)

        assert :ok = Nick.handle(user, %Message{command: "NICK", params: ["newnick"]})

        assert_sent_messages([
          {user.pid, ":irc.test 447 oldnick #stable :Cannot change nickname while on channel (+N)\r\n"}
        ])

        assert {:ok, persisted} = Users.get_by_pid(user.pid)
        assert persisted.nick == "oldnick"
      end)
    end

    test "handles NICK command with invalid nick too long" do
      nick = "nick.too.long.nick.too.long.nick.too.long"

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "NICK", params: [nick]}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 432 * #{nick} :Nickname is unavailable: Nickname too long (maximum length: 30 characters)\r\n"}
        ])
      end)
    end

    test "handles NICK command with invalid nick with illegal characters" do
      nick = "invalid.nick"

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "NICK", params: [nick]}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 432 * #{nick} :Nickname is unavailable: Illegal characters\r\n"}
        ])
      end)
    end

    test "handles NICK command with valid nick already in use" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target = insert(:user)
        message = %Message{command: "NICK", params: [target.nick]}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 433 #{user.nick} #{target.nick} :Nickname is already in use\r\n"}
        ])
      end)
    end

    test "handles NICK command with valid nick for user registered" do
      nick = "new_nick"

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "NICK", params: [nick]}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([{user.pid, ":#{user_mask(user)} NICK #{nick}\r\n"}])
      end)
    end

    test "handles NICK command with valid nick for user not registered" do
      Handshake
      |> expect(:handle, fn _user -> :ok end)

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "NICK", params: ["new_nick"]}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles NICK command with valid nick passed in the trailing" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "NICK", params: [], trailing: "new_nick"}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([{user.pid, ":#{user_mask(user)} NICK new_nick\r\n"}])
      end)
    end

    test "handles NICK command with valid nick with user in a channel with other users" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)
        another_user = insert(:user)
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        message = %Message{command: "NICK", params: ["new_nick"]}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} NICK new_nick\r\n"},
          {another_user.pid, ":#{user_mask(user)} NICK new_nick\r\n"}
        ])
      end)
    end

    test "handles NICK command trying to use reserved nickname without being identified" do
      reserved_until = DateTime.add(DateTime.utc_now(), 3600, :second)
      reserved_nick = "reserved"

      Memento.transaction!(fn ->
        insert(:registered_nick, %{nickname: reserved_nick, reserved_until: reserved_until})
        user = insert(:user, identified_as: nil)
        message = %Message{command: "NICK", params: [reserved_nick]}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 433 #{user.nick} #{reserved_nick} :This nickname is reserved. Please identify to NickServ first.\r\n"}
        ])
      end)
    end

    test "handles NICK command for user identified as the reserved nickname" do
      reserved_until = DateTime.add(DateTime.utc_now(), 3600, :second)
      reserved_nick = "reserved"

      Memento.transaction!(fn ->
        insert(:registered_nick, %{nickname: reserved_nick, reserved_until: reserved_until})
        user = insert(:user, nick: "othernick", identified_as: reserved_nick)
        message = %Message{command: "NICK", params: [reserved_nick]}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} NICK #{reserved_nick}\r\n"},
          {user.pid, ":irc.test MODE #{reserved_nick} +r\r\n"}
        ])
      end)
    end

    test "handles NICK command for user identified as the reserved nick account" do
      reserved_until = DateTime.add(DateTime.utc_now(), 3600, :second)

      Memento.transaction!(fn ->
        primary_nick = insert(:registered_nick, nickname: "PrimaryNick")

        insert(:registered_nick,
          nickname: "AliasNick",
          account_name: primary_nick.nickname,
          reserved_until: reserved_until
        )

        user = insert(:user, nick: "othernick", identified_as: primary_nick.nickname)
        message = %Message{command: "NICK", params: ["AliasNick"]}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} NICK AliasNick\r\n"},
          {user.pid, ":irc.test MODE AliasNick +r\r\n"}
        ])
      end)
    end

    test "handles NICK command for registered nickname that is not reserved" do
      nickname = "registered_not_reserved"

      Memento.transaction!(fn ->
        insert(:registered_nick, %{nickname: nickname, reserved_until: nil})
        user = insert(:user)
        message = %Message{command: "NICK", params: [nickname]}

        assert :ok = Nick.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} NICK #{nickname}\r\n"}
        ])
      end)
    end

    test "rejects an unauthorized nickname when ENFORCE is enabled" do
      Memento.transaction!(fn ->
        registered_nick =
          insert(:registered_nick,
            nickname: "EnforcedNick",
            settings: Settings.new(%{enforce: true, enforce_time: 0, kill: :off})
          )

        user = insert(:user, pid: self(), created_at: DateTime.add(DateTime.utc_now(), -60))

        assert :ok = Nick.handle(user, %Message{command: "NICK", params: [registered_nick.nickname]})

        assert_sent_messages([
          {user.pid,
           ":irc.test 433 #{user.nick} #{registered_nick.nickname} :Nickname is reserved and enforced by NickServ\r\n"}
        ])
      end)
    end

    test "disconnects an unauthorized nickname when KILL is QUICK" do
      Memento.transaction!(fn ->
        registered_nick =
          insert(:registered_nick,
            nickname: "KilledNick",
            settings: Settings.new(%{enforce: true, enforce_time: 0, kill: :quick})
          )

        user = insert(:user, pid: self(), created_at: DateTime.add(DateTime.utc_now(), -60))

        assert :ok = Nick.handle(user, %Message{command: "NICK", params: [registered_nick.nickname]})
        assert_sent_message_contains(user.pid, ~r/433 .*KilledNick.*reserved and enforced/)
        assert_received {:disconnect, "Nickname KilledNick is reserved and enforced by NickServ"}
      end)
    end

    test "allows an enforced nickname during its configured grace period" do
      Memento.transaction!(fn ->
        registered_nick =
          insert(:registered_nick,
            nickname: "GraceNick",
            settings: Settings.new(%{enforce: true, enforce_time: 3600})
          )

        user = insert(:user, created_at: DateTime.utc_now())

        assert :ok = Nick.handle(user, %Message{command: "NICK", params: [registered_nick.nickname]})
        assert_sent_message_contains(user.pid, ~r/NICK GraceNick/)
      end)
    end

    test "enforcement grace starts when the nickname is assumed and expires with a forced rename" do
      {registered_nick, user} =
        Memento.transaction!(fn ->
          registered_nick =
            insert(:registered_nick,
              nickname: "TimedNick",
              settings: Settings.new(%{enforce: true, enforce_time: 1, kill: :off})
            )

          user = insert(:user, pid: self(), nick: "GuestNick")

          {registered_nick, user}
        end)

      Memento.transaction!(fn ->
        assert :ok = Nick.handle(user, %Message{command: "NICK", params: [registered_nick.nickname]})
        {:ok, claimed_user} = Users.get_by_pid(user.pid)
        assert claimed_user.nick == registered_nick.nickname
        assert claimed_user.nick_enforcement_key == registered_nick.nickname_key
        assert %DateTime{} = claimed_user.nick_enforcement_deadline_at
        assert NickEnforcement.grace_active?(user.pid, registered_nick.nickname_key)
      end)

      assert_eventually(fn ->
        Memento.transaction!(fn ->
          {:ok, forced_user} = Users.get_by_pid(user.pid)

          forced_user.nick != registered_nick.nickname and String.starts_with?(forced_user.nick, "Guest") and
            is_nil(forced_user.nick_enforcement_key)
        end)
      end)
    end

    test "KILL QUICK caps the configured grace and KILL IMMED acts immediately" do
      Memento.transaction!(fn ->
        quick_nick =
          insert(:registered_nick,
            nickname: "QuickNick",
            settings: Settings.new(%{enforce: true, enforce_time: 3600, kill: :quick})
          )

        quick_user = insert(:user)
        assert :ok = Nick.handle(quick_user, %Message{command: "NICK", params: [quick_nick.nickname]})
        assert_sent_message_contains(quick_user.pid, ~r/within 20 seconds.*disconnected/)

        {:ok, scheduled_user} = Users.get_by_pid(quick_user.pid)
        remaining = DateTime.diff(scheduled_user.nick_enforcement_deadline_at, DateTime.utc_now(), :second)
        assert remaining in 19..20

        immediate_nick =
          insert(:registered_nick,
            nickname: "ImmediateNick",
            settings: Settings.new(%{enforce: true, enforce_time: 3600, kill: :immed})
          )

        immediate_user = insert(:user, pid: self())
        assert :ok = Nick.handle(immediate_user, %Message{command: "NICK", params: [immediate_nick.nickname]})
        assert_received {:disconnect, "Nickname ImmediateNick is reserved and enforced by NickServ"}

        {:ok, unchanged_user} = Users.get_by_pid(immediate_user.pid)
        assert unchanged_user.nick == immediate_user.nick
        NickEnforcement.cancel(quick_user.pid)
      end)
    end

    test "accepts the current enforced nickname while its exact grace timer is active" do
      Memento.transaction!(fn ->
        registered_nick =
          insert(:registered_nick,
            nickname: "ActiveGraceNick",
            settings: Settings.new(%{enforce: true, enforce_time: 60})
          )

        user = insert(:user, nick: registered_nick.nickname)
        assert :ok = NickEnforcement.schedule(user.pid, registered_nick.nickname_key, 60)

        assert :ok = Nick.handle(user, %Message{command: "NICK", params: [registered_nick.nickname]})
        refute_received {:disconnect, _reason}
        NickEnforcement.cancel(user.pid)
      end)
    end

    test "sends snotice to operators with +s mode when nick changes" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "oldnick")
        oper_with_s = insert(:user, modes: [:o, :s])
        new_nick = "newnick"
        message = %Message{command: "NICK", params: [new_nick]}

        assert :ok = Nick.handle(user, message)

        user_info = "#{new_nick}!#{user.ident}@#{user.hostname} [127.0.0.1]"
        expected_snotice = ":irc.test NOTICE :*** Nick: Nick change: oldnick -> #{new_nick} (#{user_info})\r\n"

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} NICK #{new_nick}\r\n"},
          {oper_with_s.pid, expected_snotice}
        ])
      end)
    end
  end

  defp assert_eventually(condition, attempts \\ 100)

  defp assert_eventually(condition, attempts) when attempts > 0 do
    if condition.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(condition, attempts - 1)
    end
  end

  defp assert_eventually(_condition, 0), do: flunk("condition did not become true before timeout")

  test "registered nickname mode follows account aliases across NICK changes" do
    Memento.transaction!(fn ->
      insert(:registered_nick, nickname: "Account")
      insert(:registered_nick, nickname: "Alias", account_name: "Account")
      user = insert(:user, nick: "Account", identified_as: "Account", modes: [:i, :r])

      for {nick, registered?} <- [{"Unrelated", false}, {"aLiAs", true}, {"Other", false}] do
        {:ok, user} = Users.get_by_pid(user.pid)
        Nick.handle(user, %Message{command: "NICK", params: [nick]})
        {:ok, updated} = Users.get_by_pid(user.pid)
        assert :r in updated.modes == registered?
        assert :i in updated.modes
        assert updated.identified_as == "Account"
      end
    end)
  end

  test "case-only NICK changes preserve identity and do not announce a disconnect" do
    Memento.transaction!(fn ->
      user = insert(:user, nick: "alice")
      watcher = insert(:user)
      insert(:user_monitor, user: watcher, target_nick: "alice")
      assert :ok = Nick.handle(user, %Message{command: "NICK", params: ["Alice"]})
      assert_sent_messages([{user.pid, ":#{user_mask(user)} NICK Alice\r\n"}])
      {:ok, updated} = Users.get_by_pid(user.pid)
      assert updated.nick == "Alice"
      assert updated.nick_key == "alice"
      assert :ok = Nick.handle(updated, %Message{command: "NICK", params: ["Alice"]})
      assert_sent_messages([])
    end)
  end
end
