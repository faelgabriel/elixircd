defmodule ElixIRCd.Services.Nickserv.ReleaseTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Services.Nickserv
  alias ElixIRCd.Services.Nickserv.Release

  describe "handle/2" do
    test "handles RELEASE command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Release.handle(user, ["RELEASE"])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02RELEASE\x02.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Syntax: \x02RELEASE <nickname>\x02\r\n"}
        ])
      end)
    end

    test "handles RELEASE command for non-registered nickname" do
      Memento.transaction!(fn ->
        user = insert(:user)
        non_registered_nick = "non_registered_nick"

        assert :ok = Release.handle(user, ["RELEASE", non_registered_nick])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{non_registered_nick}\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles RELEASE command for nickname with no reservation" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick, reserved_until: nil)
        user = insert(:user)

        assert :ok = Release.handle(user, ["RELEASE", registered_nick.nickname])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{registered_nick.nickname}\x02 is not reserved.\r\n"}
        ])
      end)
    end

    test "handles RELEASE command when user is not identified as the registered nick" do
      Memento.transaction!(fn ->
        reserved_until = DateTime.utc_now() |> DateTime.add(300)
        registered_nick = insert(:registered_nick, reserved_until: reserved_until)
        user = insert(:user)

        assert :ok = Release.handle(user, ["RELEASE", registered_nick.nickname])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :You must be identified with \x02#{registered_nick.nickname}\x02 to release it.\r\n"}
        ])
      end)
    end

    test "handles RELEASE command successfully" do
      Memento.transaction!(fn ->
        reserved_until = DateTime.utc_now() |> DateTime.add(300)
        registered_nick = insert(:registered_nick, reserved_until: reserved_until)
        user = insert(:user, identified_as: registered_nick.nickname)

        RegisteredNicks
        |> expect(:update, fn nick, params ->
          assert params.reserved_until == nil
          Map.merge(nick, params)
        end)

        assert :ok = Release.handle(user, ["RELEASE", registered_nick.nickname])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{registered_nick.nickname}\x02 has been released.\r\n"}
        ])
      end)
    end

    test "handles RELEASE command for IRC operators bypassing identification" do
      Memento.transaction!(fn ->
        reserved_until = DateTime.utc_now() |> DateTime.add(300)
        registered_nick = insert(:registered_nick, reserved_until: reserved_until)
        user = insert(:user, modes: ["o"])

        Nickserv
        |> expect(:notify, fn ^user, message ->
          assert message =~ "has been released"
          :ok
        end)

        RegisteredNicks
        |> expect(:update, fn nick, params ->
          assert params.reserved_until == nil
          Map.merge(nick, params)
        end)

        assert :ok = Release.handle(user, ["RELEASE", registered_nick.nickname])
      end)
    end
  end
end
