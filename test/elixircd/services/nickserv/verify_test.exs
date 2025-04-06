defmodule ElixIRCd.Services.Nickserv.VerifyTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Services.Nickserv.Verify
  alias ElixIRCd.Utils.Nickserv

  describe "handle/2" do
    test "handles VERIFY command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Verify.handle(user, ["VERIFY"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02VERIFY\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02VERIFY <nickname> <code>\x02\r\n"}
        ])
      end)
    end

    test "handles VERIFY command with only one parameter" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Verify.handle(user, ["VERIFY", "nickname"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02VERIFY\x02.\r\n"},
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02VERIFY <nickname> <code>\x02\r\n"}
        ])
      end)
    end

    test "handles VERIFY command for non-registered nickname" do
      Memento.transaction!(fn ->
        user = insert(:user)
        non_registered_nick = "non_registered_nick"

        assert :ok = Verify.handle(user, ["VERIFY", non_registered_nick, "verify_code"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nickname \x02#{non_registered_nick}\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles VERIFY command for already verified nickname" do
      Memento.transaction!(fn ->
        verify_code = "verify_code"
        registered_nick = insert(:registered_nick, verify_code: verify_code, verified_at: DateTime.utc_now())
        user = insert(:user)

        assert :ok = Verify.handle(user, ["VERIFY", registered_nick.nickname, verify_code])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nickname \x02#{registered_nick.nickname}\x02 is already verified.\r\n"}
        ])
      end)
    end

    test "handles VERIFY command for nickname that doesn't require verification" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick, verify_code: nil, verified_at: nil)
        user = insert(:user)

        Nickserv
        |> expect(:notify, fn _user, message ->
          assert message == "Nickname \x02#{registered_nick.nickname}\x02 does not require verification."
          :ok
        end)

        assert :ok = Verify.handle(user, ["VERIFY", registered_nick.nickname, "any_code"])
      end)
    end

    test "handles VERIFY command with invalid verification code" do
      Memento.transaction!(fn ->
        correct_code = "correct_code"
        wrong_code = "wrong_code"
        registered_nick = insert(:registered_nick, verify_code: correct_code, verified_at: nil)
        user = insert(:user)

        assert :ok = Verify.handle(user, ["VERIFY", registered_nick.nickname, wrong_code])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Verification failed. Invalid code for nickname \x02#{registered_nick.nickname}\x02.\r\n"}
        ])
      end)
    end

    test "handles VERIFY command successfully when user is using the same nickname" do
      Memento.transaction!(fn ->
        verify_code = "verify_code"
        registered_nick = insert(:registered_nick, verify_code: verify_code, verified_at: nil)
        user = insert(:user, nick: registered_nick.nickname)

        assert :ok = Verify.handle(user, ["VERIFY", registered_nick.nickname, verify_code])

        {:ok, updated_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
        assert updated_nick.verify_code == nil
        assert updated_nick.verified_at != nil

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == registered_nick.nickname

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nickname \x02#{registered_nick.nickname}\x02 has been successfully verified.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You are now identified for \x02#{registered_nick.nickname}\x02.\r\n"}
        ])
      end)
    end

    test "handles VERIFY command successfully when user is using a different nickname" do
      Memento.transaction!(fn ->
        verify_code = "verify_code"
        registered_nick = insert(:registered_nick, verify_code: verify_code, verified_at: nil)
        user = insert(:user)

        assert :ok = Verify.handle(user, ["VERIFY", registered_nick.nickname, verify_code])

        {:ok, updated_nick} = RegisteredNicks.get_by_nickname(registered_nick.nickname)
        assert updated_nick.verify_code == nil
        assert updated_nick.verified_at != nil

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.identified_as == nil

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nickname \x02#{registered_nick.nickname}\x02 has been successfully verified.\r\n"},
          {user.pid, ~r/NickServ.*NOTICE.*You can now identify for this nickname using:.*/}
        ])
      end)
    end
  end
end
