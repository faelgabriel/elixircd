defmodule ElixIRCd.Services.Nickserv.RegainTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Nick
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Services.Nickserv.Identify
  alias ElixIRCd.Services.Nickserv.Regain

  describe "handle/2" do
    test "handles REGAIN command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Regain.handle(user, ["REGAIN"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02REGAIN\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02REGAIN <nickname> <password>\x02\r\n"}
        ])
      end)
    end

    test "handles REGAIN command for non-registered nickname" do
      Memento.transaction!(fn ->
        user = insert(:user)
        non_registered_nick = "non_registered_nick"

        assert :ok = Regain.handle(user, ["REGAIN", non_registered_nick])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{non_registered_nick}\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles REGAIN command for registered nick without providing password" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user)

        assert :ok = Regain.handle(user, ["REGAIN", registered_nick.nickname])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02REGAIN\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02REGAIN <nickname> <password>\x02\r\n"}
        ])
      end)
    end

    test "handles REGAIN command for registered nick with incorrect password" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user)

        assert :ok = Regain.handle(user, ["REGAIN", registered_nick.nickname, "wrong_password"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Invalid password for \x02#{registered_nick.nickname}\x02.\r\n"}
        ])
      end)
    end

    test "handles REGAIN command for registered nick with correct password when nick is not in use" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user)
        old_nick = user.nick

        assert :ok = Regain.handle(user, ["REGAIN", registered_nick.nickname, password])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.nick == registered_nick.nickname

        assert_sent_messages([
          {user.pid, ":#{old_nick}!#{user.ident}@#{user.hostname} NICK #{registered_nick.nickname}\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You have regained the nickname \x02#{registered_nick.nickname}\x02.\r\n"}
        ])
      end)
    end

    test "handles REGAIN command when canonical account cannot be resolved" do
      Memento.transaction!(fn ->
        insert(:registered_nick,
          nickname: "AliasNick",
          account_name: "MissingAccount",
          password_hash: Argon2.hash_pwd_salt("correct_password")
        )

        user = insert(:user)

        assert :ok = Regain.handle(user, ["REGAIN", "AliasNick", "correct_password"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02AliasNick\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles REGAIN command when user is already identified as the registered nick" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname)
        old_nick = user.nick

        assert :ok = Regain.handle(user, ["REGAIN", registered_nick.nickname])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.nick == registered_nick.nickname

        assert_sent_messages([
          {user.pid, ":#{old_nick}!#{user.ident}@#{user.hostname} NICK #{registered_nick.nickname}\r\n"},
          {user.pid, ":irc.test MODE #{updated_user.nick} +r\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You have regained the nickname \x02#{registered_nick.nickname}\x02.\r\n"}
        ])
      end)
    end

    test "handles REGAIN command when user is identified to the grouped nick account" do
      Memento.transaction!(fn ->
        primary_nick = insert(:registered_nick, nickname: "PrimaryNick")
        _grouped_nick = insert(:registered_nick, nickname: "AliasNick", account_name: primary_nick.nickname)
        user = insert(:user, identified_as: primary_nick.nickname)
        old_nick = user.nick

        assert :ok = Regain.handle(user, ["REGAIN", "AliasNick"])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.nick == "AliasNick"

        assert_sent_messages([
          {user.pid, ":#{old_nick}!#{user.ident}@#{user.hostname} NICK AliasNick\r\n"},
          {user.pid, ":irc.test MODE #{updated_user.nick} +r\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You have regained the nickname \x02AliasNick\x02.\r\n"}
        ])
      end)
    end

    test "handles REGAIN command for trying to regain your own session" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user, nick: registered_nick.nickname)

        assert :ok = Regain.handle(user, ["REGAIN", registered_nick.nickname, password])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :You cannot regain your own session.\r\n"}
        ])
      end)
    end

    test "handles REGAIN command for registered nick with correct password when nick is in use" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)

        target_pid = spawn_test_process()
        _target_user = insert(:user, nick: registered_nick.nickname, pid: target_pid)

        user = insert(:user)
        old_nick = user.nick

        assert :ok = Regain.handle(user, ["REGAIN", registered_nick.nickname, password])

        {:ok, updated_registered_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
        assert not is_nil(updated_registered_nick.reserved_until)

        # No synchronous nick take: the holder disconnects asynchronously, so the owner claims it with /NICK.
        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.nick == old_nick

        reservation_duration =
          Application.get_env(:elixircd, :services)[:nickserv][:regain_reservation_duration] || 60

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{registered_nick.nickname}\x02 has been regained and reserved for you for \x02#{reservation_duration} seconds\x02.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Use \x02/NICK #{registered_nick.nickname}\x02 to take it (identify first with \x02/msg NickServ IDENTIFY #{registered_nick.nickname} <password>\x02 if needed).\r\n"}
        ])

        expected_message = "Killed (#{old_nick} (REGAIN command used))"
        assert_received {:regain_test, {:disconnect, ^expected_message}}
      end)
    end

    test "handles REGAIN command when user is in a channel with other users" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)

        channel = insert(:channel)
        user = insert(:user)
        another_user = insert(:user)
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: another_user, channel: channel)

        old_nick = user.nick

        assert :ok = Regain.handle(user, ["REGAIN", registered_nick.nickname, password])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.nick == registered_nick.nickname

        assert_sent_messages([
          {user.pid, ":#{old_nick}!#{user.ident}@#{user.hostname} NICK #{registered_nick.nickname}\r\n"},
          {another_user.pid, ":#{old_nick}!#{user.ident}@#{user.hostname} NICK #{registered_nick.nickname}\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You have regained the nickname \x02#{registered_nick.nickname}\x02.\r\n"}
        ])
      end)
    end
  end

  test "reservation serializes concurrent disconnect and NICK, and the owner can claim it before expiry" do
    parent = self()

    holder =
      spawn(fn ->
        receive do
          {:disconnect, _reason} ->
            send(parent, :disconnect_started)

            Memento.transaction!(fn ->
              {:ok, user} = Users.get_by_pid(self())
              Users.delete(user)
            end)

            send(parent, :holder_released)
        end
      end)

    {owner, outsider} =
      Memento.transaction!(fn ->
        insert(:registered_nick, nickname: "ReservedOwner", password: "password")
        insert(:user, pid: holder, nick: "ReservedOwner")
        {insert(:user, nick: "OwnerSession"), insert(:user, nick: "Contender")}
      end)

    regainer =
      Task.async(fn ->
        Mimic.allow(Connection, parent, self())

        Memento.transaction!(fn ->
          Regain.handle(owner, ["REGAIN", "ReservedOwner", "password"])
          send(parent, {:reservation_staged, self()})

          receive do
            :commit -> :ok
          after
            5000 -> raise "reservation commit barrier timed out"
          end
        end)
      end)

    assert_receive :disconnect_started, 5000
    assert_receive {:reservation_staged, regainer_pid}, 5000

    contender =
      Task.async(fn ->
        Mimic.allow(Connection, parent, self())
        send(parent, :contender_started)

        Memento.transaction!(fn ->
          Nick.handle(outsider, %Message{command: "NICK", params: ["ReservedOwner"]})
        end)
      end)

    assert_receive :contender_started, 5000
    send(regainer_pid, :commit)
    Task.await(regainer)
    Task.await(contender)
    assert_receive :holder_released, 5000

    Memento.transaction!(fn ->
      {:ok, attempted} = Users.get_by_pid(outsider.pid)
      assert attempted.nick == "Contender"
      {:ok, reserved} = RegisteredNicks.get_by_nickname("ReservedOwner")
      assert DateTime.compare(reserved.reserved_until, DateTime.utc_now()) == :gt
      assert_sent_messages_count_containing(outsider.pid, ~r/ 433 .* ReservedOwner /, 1)

      Identify.handle(owner, ["IDENTIFY", "ReservedOwner", "password"])
      {:ok, owner} = Users.get_by_pid(owner.pid)
      Nick.handle(owner, %Message{command: "NICK", params: ["ReservedOwner"]})
      {:ok, claimed} = Users.get_by_nick("ReservedOwner")
      assert claimed.pid == owner.pid
      assert "r" in claimed.modes
      assert Enum.count(Users.get_all(), &(&1.nick_key == reserved.nickname_key)) == 1
    end)
  end

  @spec spawn_test_process() :: pid()
  defp spawn_test_process do
    parent = self()

    spawn(fn ->
      receive do
        message -> send(parent, {:regain_test, message})
      end
    end)
  end
end
