defmodule ElixIRCd.Services.Nickserv.InfoTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Nickserv.Info
  alias ElixIRCd.Tables.RegisteredNick.Settings

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
        user = insert(:user, modes: [:o])

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

        user = insert(:user, modes: [:o])

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

    test "handles INFO command for a grouped nickname showing group info" do
      Memento.transaction!(fn ->
        primary_nick = insert(:registered_nick, nickname: "PrimaryNick")

        grouped_nick =
          insert(:registered_nick,
            nickname: "AliasNick",
            account_name: primary_nick.nickname,
            password_hash: primary_nick.password_hash
          )

        user = insert(:user, identified_as: primary_nick.nickname)

        assert :ok = Info.handle(user, ["INFO", grouped_nick.nickname])

        assert_sent_message_contains(user.pid, ~r/Grouped with:.*PrimaryNick/)
      end)
    end

    test "handles INFO command when grouped nick canonical account cannot be resolved" do
      Memento.transaction!(fn ->
        insert(:registered_nick,
          nickname: "AliasNick",
          account_name: "MissingAccount",
          password_hash: Argon2.hash_pwd_salt("correct_password")
        )

        user = insert(:user)

        assert :ok = Info.handle(user, ["INFO", "AliasNick"])

        assert_sent_messages([
          {user.pid, ":NickServ!service@irc.test NOTICE #{user.nick} :Nick \x02AliasNick\x02 is not registered.\r\n"}
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
      operator_user = insert(:user, modes: [:o])

      visible_nick =
        insert(:registered_nick,
          nickname: "VisibleEmail",
          email: "visible@example.com",
          settings: %{hide_email: false}
        )

      regular_user = insert(:user)

      Memento.transaction!(fn ->
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

    test "applies the individual privacy settings to public INFO status and operator views" do
      Memento.transaction!(fn ->
        private_status = insert(:registered_nick, nickname: "PrivateStatus", settings: %{hide_status: true})
        regular_user = insert(:user)

        assert :ok = Info.handle(regular_user, ["INFO", private_status.nickname])
        assert_sent_message_contains(regular_user.pid, ~r/Online status is private/)

        private_fields =
          insert(:registered_nick,
            nickname: "PrivateFields",
            settings: %{hide_quit: true, hide_usermask: true},
            last_seen_at: DateTime.utc_now()
          )

        operator = insert(:user, modes: [:o])

        assert :ok = Info.handle(operator, ["INFO", private_fields.nickname])
        assert_sent_message_contains(operator.pid, ~r/Last seen information is private/)
        assert_sent_message_contains(operator.pid, ~r/Registration mask is private/)
      end)
    end

    test "shows the complete account settings and operational flags to the owner" do
      Memento.transaction!(fn ->
        account =
          insert(:registered_nick,
            nickname: "Account",
            email: "account@example.com",
            settings:
              Settings.new(%{
                display: "DisplayName",
                url: "https://example.com/account",
                property: %{"role" => "admin"},
                msg: true,
                email_memos: :on,
                kill: :quick,
                hide_email: true,
                hide_status: true,
                hide_usermask: true,
                hide_quit: true,
                enforce: true,
                never_group: true,
                never_op: true,
                no_greet: true,
                private: true,
                quiet_chg: true,
                secure: true
              })
          )

        owner = insert(:user, nick: account.nickname, identified_as: account.account_name)

        assert :ok = Info.handle(owner, ["INFO", account.nickname])
        assert_sent_message_contains(owner.pid, ~r/Display name:/)
        assert_sent_message_contains(owner.pid, ~r/URL:/)
        assert_sent_message_contains(owner.pid, ~r/Properties:/)
        assert_sent_message_contains(owner.pid, ~r/Email address:/)
        assert_sent_message_contains(owner.pid, ~r/MSG/)
        assert_sent_message_contains(owner.pid, ~r/EMAILMEMOS=ON/)
        assert_sent_message_contains(owner.pid, ~r/KILL=QUICK/)
        assert_sent_message_contains(owner.pid, ~r/HIDEMAIL/)
        assert_sent_message_contains(owner.pid, ~r/HIDESTATUS/)
        assert_sent_message_contains(owner.pid, ~r/HIDEUSERMASK/)
        assert_sent_message_contains(owner.pid, ~r/HIDEQUIT/)
        assert_sent_message_contains(owner.pid, ~r/ENFORCE/)
        assert_sent_message_contains(owner.pid, ~r/NEVERGROUP/)
        assert_sent_message_contains(owner.pid, ~r/NEVEROP/)
        assert_sent_message_contains(owner.pid, ~r/NOGREET/)
        assert_sent_message_contains(owner.pid, ~r/PRIVATE/)
        assert_sent_message_contains(owner.pid, ~r/QUIETCHG/)
        assert_sent_message_contains(owner.pid, ~r/SECURE/)
      end)
    end
  end
end
