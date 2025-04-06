defmodule ElixIRCd.Services.Nickserv.InfoTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Nickserv.Info

  describe "handle/2" do
    test "handles INFO command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Info.handle(user, ["INFO", "target", "extra"])

        assert_sent_messages([
          {user.pid, ~r/Nick \x02target\x02 is not registered/}
        ])
      end)
    end

    test "handles INFO command for non-registered nickname" do
      Memento.transaction!(fn ->
        user = insert(:user)
        non_registered_nick = "non_registered_nick"

        assert :ok = Info.handle(user, ["INFO", non_registered_nick])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{non_registered_nick}\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles INFO command with no parameters (uses current nick)" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Info.handle(user, ["INFO"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02#{user.nick}\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "handles INFO command for registered nick when user is identified as that nick" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick, settings: %{hide_email: false})
        user = insert(:user, nick: registered_nick.nickname, identified_as: registered_nick.nickname)

        assert :ok = Info.handle(user, ["INFO", registered_nick.nickname])

        assert_sent_message_contains(user.pid, ~r/\*\*\*.*#{registered_nick.nickname}.*\*\*\*/)
        assert_sent_message_contains(user.pid, ~r/is currently online/)
        assert_sent_message_contains(user.pid, ~r/Registered on:/)

        assert_sent_messages_amount(user.pid, 6)
      end)
    end

    test "handles INFO command for registered nick when user is not identified as that nick" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick)
        user = insert(:user)

        assert :ok = Info.handle(user, ["INFO", registered_nick.nickname])

        assert_sent_messages([
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :\x02\x0312*** \x0304#{registered_nick.nickname}\x0312 ***\x03\x02\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :\x02#{registered_nick.nickname}\x02 is not currently online.\r\n"},
          {user.pid,
           ":NickServ!service@irc.test NOTICE #{user.nick} :The information for this nickname is private.\r\n"}
        ])
      end)
    end

    test "handles INFO command when user is IRC operator" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick, email: "user@example.com")
        user = insert(:user, modes: ["o"])

        assert :ok = Info.handle(user, ["INFO", registered_nick.nickname])

        assert_sent_message_contains(user.pid, ~r/\*\*\*.*#{registered_nick.nickname}.*\*\*\*/)
        assert_sent_message_contains(user.pid, ~r/Registered on:/)
        assert_sent_message_contains(user.pid, ~r/Email address:.*user@example.com/)

        assert_sent_messages_amount(user.pid, 6)
      end)
    end

    test "handles INFO command for nickname with hide_email setting" do
      Memento.transaction!(fn ->
        registered_nick =
          insert(:registered_nick,
            email: "user@example.com",
            settings: %{hide_email: true}
          )

        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Info.handle(user, ["INFO", registered_nick.nickname])

        assert_sent_message_contains(user.pid, ~r/Email address:.*user@example.com/)
        assert_sent_message_contains(user.pid, ~r/Flags:.*HIDEMAIL/)

        assert_sent_messages_amount(user.pid, 7)
      end)
    end

    test "handles INFO command for unverified nickname" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick, verified_at: nil)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Info.handle(user, ["INFO", registered_nick.nickname])

        assert_sent_message_contains(user.pid, ~r/Flags:.*UNVERIFIED/)

        assert_sent_messages_amount(user.pid, 7)
      end)
    end
  end
end
