defmodule ElixIRCd.Services.Nickserv.DropTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Services.Nickserv.Drop

  describe "handle/2" do
    test "handles DROP command with no parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Drop.handle(user, ["DROP"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{user.nick}\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles DROP command with no parameters for a registered nick" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, nick: registered_nick.nickname, identified_as: registered_nick.nickname, modes: ["r"])

        assert :ok = Drop.handle(user, ["DROP"])

        assert_sent_messages([
          {user.pid, ":irc.test MODE #{user.nick} -r\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{registered_nick.nickname}\x02 has been dropped.\r\n"}
        ])

        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname(registered_nick.nickname)

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil
        assert "r" not in updated_user.modes
      end)
    end

    test "handles DROP command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        registered_nick = insert(:registered_nick)

        assert :ok = Drop.handle(user, ["DROP", registered_nick.nickname])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02DROP\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02DROP <nickname> <password>\x02\r\n"}
        ])
      end)
    end

    test "handles DROP command for non-registered nickname" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Drop.handle(user, ["DROP", "non_registered_nick"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02non_registered_nick\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles DROP command for identified user dropping their own nick" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, nick: registered_nick.nickname, identified_as: registered_nick.nickname, modes: ["r"])

        assert :ok = Drop.handle(user, ["DROP", registered_nick.nickname])

        assert_sent_messages([
          {user.pid, ":irc.test MODE #{user.nick} -r\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{registered_nick.nickname}\x02 has been dropped.\r\n"}
        ])

        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname(registered_nick.nickname)

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil
        assert "r" not in updated_user.modes
      end)
    end

    test "handles DROP command for non-identified user with correct password" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user)

        assert :ok = Drop.handle(user, ["DROP", registered_nick.nickname, password])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{registered_nick.nickname}\x02 has been dropped.\r\n"}
        ])

        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
      end)
    end

    test "handles DROP command for non-identified user with incorrect password" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)
        user = insert(:user)

        assert :ok = Drop.handle(user, ["DROP", registered_nick.nickname, "wrong_password"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Authentication failed. Invalid password for \x02#{registered_nick.nickname}\x02.\r\n"}
        ])

        assert {:ok, _} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
      end)
    end

    test "handles DROP command for non-identified user without providing password" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user)

        assert :ok = Drop.handle(user, ["DROP", registered_nick.nickname])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02DROP\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02DROP <nickname> <password>\x02\r\n"}
        ])
      end)
    end

    test "handles DROP command that affects currently connected user with that nick" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)

        user = insert(:user)

        target_user =
          insert(:user, nick: registered_nick.nickname, identified_as: registered_nick.nickname, modes: ["r"])

        assert :ok = Drop.handle(user, ["DROP", registered_nick.nickname, password])

        {:ok, updated_target_user} = Users.get_by_pid(target_user.pid)
        assert updated_target_user.identified_as == nil
        assert "r" not in updated_target_user.modes
      end)
    end

    test "handles DROP command for user identified as nickname but using different current nick" do
      Memento.transaction!(fn ->
        password = "correct_password"
        password_hash = Argon2.hash_pwd_salt(password)
        registered_nick = insert(:registered_nick, password_hash: password_hash)

        user = insert(:user, nick: "different_nick", identified_as: registered_nick.nickname, modes: ["r"])

        assert :ok = Drop.handle(user, ["DROP", registered_nick.nickname, password])

        assert_sent_messages([
          {user.pid, ":irc.test MODE #{user.nick} -r\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{registered_nick.nickname}\x02 has been dropped.\r\n"}
        ])

        assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname(registered_nick.nickname)

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil
        assert "r" not in updated_user.modes
      end)
    end
  end
end
