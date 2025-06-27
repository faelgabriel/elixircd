defmodule ElixIRCd.Services.Nickserv.LogoutTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Services.Nickserv.Logout

  describe "handle/2" do
    test "handles LOGOUT command when user is not identified" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Logout.handle(user, ["LOGOUT"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :You are not identified to any nickname.\r\n"}
        ])
      end)
    end

    test "handles LOGOUT command when user is identified" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname, modes: ["r"])

        assert :ok = Logout.handle(user, ["LOGOUT"])

        assert_sent_messages([
          {user.pid, ":irc.test MODE #{user.nick} -r\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You are now logged out from \x02#{registered_nick.nickname}\x02.\r\n"}
        ])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil
        assert "r" not in updated_user.modes
      end)
    end

    test "handles LOGOUT command when user is identified but doesn't have +r mode" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user, identified_as: registered_nick.nickname, modes: [])

        assert :ok = Logout.handle(user, ["LOGOUT"])

        assert_sent_messages([
          {user.pid, ":irc.test MODE #{user.nick} -r\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You are now logged out from \x02#{registered_nick.nickname}\x02.\r\n"}
        ])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil
        assert updated_user.modes == []
      end)
    end

    test "handles LOGOUT command with extra parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Logout.handle(user, ["LOGOUT", "extra", "params"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Too many parameters for \x02LOGOUT\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02LOGOUT\x02\r\n"}
        ])
      end)
    end
  end
end
