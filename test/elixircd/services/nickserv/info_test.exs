defmodule ElixIRCd.Services.Nickserv.InfoTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Nickserv.Info

  describe "handle/2" do
    test "handles INFO command with extra parameters" do
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

    test "displays 'Last seen: never' when last_seen_at is nil" do
      Memento.transaction!(fn ->
        registered_nick = insert(:registered_nick, last_seen_at: nil)
        user = insert(:user, identified_as: registered_nick.nickname)

        assert :ok = Info.handle(user, ["INFO", registered_nick.nickname])

        assert_sent_message_contains(user.pid, ~r/Last seen: never/)
        assert_sent_messages_amount(user.pid, 6)
      end)
    end

    test "shows email when hide_email is false for any viewer with full info" do
      Memento.transaction!(fn ->
        registered_nick =
          insert(:registered_nick,
            email: "user@example.com",
            settings: %{hide_email: false}
          )

        # User is an IRC operator but not identified as the nick
        user = insert(:user, modes: ["o"])

        assert :ok = Info.handle(user, ["INFO", registered_nick.nickname])

        assert_sent_message_contains(user.pid, ~r/Email address:.*user@example.com/)
        assert_sent_messages_amount(user.pid, 6)
      end)
    end

    test "does not show email when hide_email is true and user is not identified or operator" do
      user = insert(:user)

      registered_nick =
        insert(:registered_nick,
          email: "user@example.com",
          settings: %{hide_email: true}
        )

      Memento.transaction!(fn ->
        assert :ok = Info.handle(user, ["INFO", registered_nick.nickname])

        assert_sent_messages([
          {user.pid,
           ~r/:NickServ!service@irc.test NOTICE #{user.nick} :\x02\x0312\*\*\* \x0304#{registered_nick.nickname}\x0312 \*\*\*\x03\x02/},
          {user.pid,
           ~r/:NickServ!service@irc.test NOTICE #{user.nick} :\x02#{registered_nick.nickname}\x02 is not currently online\./},
          {user.pid, ~r/:NickServ!service@irc.test NOTICE #{user.nick} :The information for this nickname is private\./}
        ])
      end)
    end

    test "email visibility respects complex privacy rules" do
      registered_nick =
        insert(:registered_nick,
          email: "private@example.com",
          settings: %{hide_email: true}
        )

      identified_user = insert(:user, identified_as: registered_nick.nickname)
      operator_user = insert(:user, modes: ["o"])

      visible_nick =
        insert(:registered_nick,
          nickname: "VisibleEmail",
          email: "visible@example.com",
          settings: %{hide_email: false}
        )

      regular_user = insert(:user)

      Memento.transaction!(fn ->
        # User is identified as the nick - should see email despite hide_email
        assert :ok = Info.handle(identified_user, ["INFO", registered_nick.nickname])

        assert_sent_messages([
          {identified_user.pid,
           ~r/:NickServ!service@irc.test NOTICE #{identified_user.nick} :\x02\x0312\*\*\* \x0304#{registered_nick.nickname}\x0312 \*\*\*\x03\x02/},
          {identified_user.pid,
           ~r/:NickServ!service@irc.test NOTICE #{identified_user.nick} :\x02#{registered_nick.nickname}\x02 is not currently online\./},
          {identified_user.pid, ~r/:NickServ!service@irc.test NOTICE #{identified_user.nick} :Registered on:/},
          {identified_user.pid, ~r/:NickServ!service@irc.test NOTICE #{identified_user.nick} :Last seen:/},
          {identified_user.pid, ~r/:NickServ!service@irc.test NOTICE #{identified_user.nick} :Registered from:/},
          {identified_user.pid,
           ~r/:NickServ!service@irc.test NOTICE #{identified_user.nick} :Email address:.*private@example.com/},
          {identified_user.pid, ~r/:NickServ!service@irc.test NOTICE #{identified_user.nick} :Flags:.*HIDEMAIL/}
        ])

        # User is an operator - should see email despite hide_email
        assert :ok = Info.handle(operator_user, ["INFO", registered_nick.nickname])

        assert_sent_messages([
          {operator_user.pid,
           ~r/:NickServ!service@irc.test NOTICE #{operator_user.nick} :\x02\x0312\*\*\* \x0304#{registered_nick.nickname}\x0312 \*\*\*\x03\x02/},
          {operator_user.pid,
           ~r/:NickServ!service@irc.test NOTICE #{operator_user.nick} :\x02#{registered_nick.nickname}\x02 is not currently online\./},
          {operator_user.pid, ~r/:NickServ!service@irc.test NOTICE #{operator_user.nick} :Registered on:/},
          {operator_user.pid, ~r/:NickServ!service@irc.test NOTICE #{operator_user.nick} :Last seen:/},
          {operator_user.pid, ~r/:NickServ!service@irc.test NOTICE #{operator_user.nick} :Registered from:/},
          {operator_user.pid,
           ~r/:NickServ!service@irc.test NOTICE #{operator_user.nick} :Email address:.*private@example.com/},
          {operator_user.pid, ~r/:NickServ!service@irc.test NOTICE #{operator_user.nick} :Flags:.*HIDEMAIL/}
        ])

        # Regular user with non-hidden email - would see email if they had full info
        # but they don't because they're not identified, so they get private view
        assert :ok = Info.handle(regular_user, ["INFO", visible_nick.nickname])

        assert_sent_messages([
          {regular_user.pid,
           ~r/:NickServ!service@irc.test NOTICE #{regular_user.nick} :\x02\x0312\*\*\* \x0304#{visible_nick.nickname}\x0312 \*\*\*\x03\x02/},
          {regular_user.pid,
           ~r/:NickServ!service@irc.test NOTICE #{regular_user.nick} :\x02#{visible_nick.nickname}\x02 is not currently online\./},
          {regular_user.pid,
           ~r/:NickServ!service@irc.test NOTICE #{regular_user.nick} :The information for this nickname is private\./}
        ])
      end)
    end
  end
end
