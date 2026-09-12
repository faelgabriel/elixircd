defmodule ElixIRCd.Commands.WhoTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Who
  alias ElixIRCd.Message

  describe "WHOX and hidden operator regressions" do
    setup do
      original = Application.get_env(:elixircd, :whox)
      on_exit(fn -> Application.put_env(:elixircd, :whox, original) end)
      Application.put_env(:elixircd, :whox, enabled: true)
    end

    for fields <- ["%ranft,42", "%tfnar,42", "%annftr?,42"] do
      test "returns canonical WHOX fields for #{fields}" do
        Memento.transaction!(fn ->
          user = insert(:user)
          target = insert(:user, nick: "target", identified_as: "Account", realname: "A real name")

          assert :ok = Who.handle(user, %Message{command: "WHO", params: [target.nick, unquote(fields)]})

          assert_sent_messages([
            {user.pid, ":irc.test 354 #{user.nick} 42 target H Account :A real name\r\n"},
            {user.pid, ":irc.test 315 #{user.nick} target :End of WHO list\r\n"}
          ])
        end)
      end
    end

    for oper? <- [false, true], shared? <- [false, true] do
      test "WHO hides only oper status with viewer oper=#{oper?}, shared=#{shared?}" do
        Memento.transaction!(fn ->
          user = insert(:user, modes: if(unquote(oper?), do: ["o"], else: []))
          target = insert(:user, nick: "hidden", modes: ["o", "H"])

          if unquote(shared?) do
            channel = insert(:channel)
            insert(:user_channel, user: user, channel: channel)
            insert(:user_channel, user: target, channel: channel)
          end

          assert :ok = Who.handle(user, %Message{command: "WHO", params: [target.nick, "%nf"]})
          flags = if unquote(oper?), do: "H*", else: "H"
          assert_sent_message_contains(user.pid, ":irc.test 354 #{user.nick} hidden #{flags}\r\n")
        end)
      end

      test "WHO o respects hidden oper status with viewer oper=#{oper?}, shared=#{shared?}" do
        Memento.transaction!(fn ->
          user = insert(:user, modes: if(unquote(oper?), do: ["o"], else: []))
          target = insert(:user, nick: "hidden", modes: ["o", "H"])

          if unquote(shared?) do
            channel = insert(:channel)
            insert(:user_channel, user: user, channel: channel)
            insert(:user_channel, user: target, channel: channel)
          end

          assert :ok = Who.handle(user, %Message{command: "WHO", params: [target.nick, "o"]})
          assert_sent_messages_count_containing(user.pid, ~r/ 352 /, if(unquote(oper?), do: 1, else: 0))
          assert_sent_messages_count_containing(user.pid, ~r/ 315 /, 1)
        end)
      end
    end
  end

  describe "handle/2" do
    test "handles WHO command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "WHO", params: ["#anything"]}

        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles WHO command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHO", params: []}

        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} WHO :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles WHO command with inexistent channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHO", params: ["#anything"]}

        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 315 #{user.nick} #anything :End of WHO list\r\n"}
        ])
      end)
    end

    test "handles WHO command with channel target and user shares channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)
        insert(:user_channel, channel: channel, user: user)

        another_user1 = insert(:user, modes: ["o"])
        another_user2 = insert(:user, modes: ["o"])
        another_user3 = insert(:user, modes: ["i"])
        another_user4 = insert(:user, away_message: "away")
        insert(:user_channel, channel: channel, user: another_user1)
        insert(:user_channel, channel: channel, user: another_user2, modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user3, modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user4, modes: ["v"])

        message = %Message{command: "WHO", params: [channel.name]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.pid,
             ":irc.test 352 #{user.nick} #{channel.name} #{user.ident} hostname irc.test #{another_user1.nick} H* :0 realname\r\n"},
            {user.pid,
             ":irc.test 352 #{user.nick} #{channel.name} #{user.ident} hostname irc.test #{another_user2.nick} H*@ :0 realname\r\n"},
            {user.pid,
             ":irc.test 352 #{user.nick} #{channel.name} #{user.ident} hostname irc.test #{another_user3.nick} H@ :0 realname\r\n"},
            {user.pid,
             ":irc.test 352 #{user.nick} #{channel.name} #{user.ident} hostname irc.test #{another_user4.nick} G+ :0 realname\r\n"},
            {user.pid,
             ":irc.test 352 #{user.nick} #{channel.name} #{user.ident} hostname irc.test #{user.nick} H :0 realname\r\n"},
            {user.pid, ":irc.test 315 #{user.nick} #{channel.name} :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "handles WHO command with channel target and user does not share channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)

        another_user1 = insert(:user, modes: ["o"])
        another_user2 = insert(:user, modes: ["o"])
        another_user3 = insert(:user, modes: ["i"])
        another_user4 = insert(:user, away_message: "away")
        insert(:user_channel, channel: channel, user: another_user1)
        insert(:user_channel, channel: channel, user: another_user2, modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user3, modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user4, modes: ["v"])

        message = %Message{command: "WHO", params: [channel.name]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.pid,
             ":irc.test 352 #{user.nick} #{channel.name} #{user.ident} hostname irc.test #{another_user1.nick} H* :0 realname\r\n"},
            {user.pid,
             ":irc.test 352 #{user.nick} #{channel.name} #{user.ident} hostname irc.test #{another_user2.nick} H*@ :0 realname\r\n"},
            {user.pid,
             ":irc.test 352 #{user.nick} #{channel.name} #{user.ident} hostname irc.test #{another_user4.nick} G+ :0 realname\r\n"},
            {user.pid, ":irc.test 315 #{user.nick} #{channel.name} :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "handles WHO command with channel target and user shares secret channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["s"])
        insert(:user_channel, channel: channel, user: user)

        another_user1 = insert(:user)
        another_user2 = insert(:user, modes: ["i"])
        insert(:user_channel, channel: channel, user: another_user1)
        insert(:user_channel, channel: channel, user: another_user2)

        message = %Message{command: "WHO", params: [channel.name]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.pid,
             ":irc.test 352 #{user.nick} #{channel.name} #{user.ident} hostname irc.test #{another_user1.nick} H :0 realname\r\n"},
            {user.pid,
             ":irc.test 352 #{user.nick} #{channel.name} #{user.ident} hostname irc.test #{another_user2.nick} H :0 realname\r\n"},
            {user.pid,
             ":irc.test 352 #{user.nick} #{channel.name} #{user.ident} hostname irc.test #{user.nick} H :0 realname\r\n"},
            {user.pid, ":irc.test 315 #{user.nick} #{channel.name} :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "handles WHO command with channel target and user does not share secret channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["s"])

        another_user1 = insert(:user)
        another_user2 = insert(:user, modes: ["i"])
        insert(:user_channel, channel: channel, user: another_user1)
        insert(:user_channel, channel: channel, user: another_user2)

        message = %Message{command: "WHO", params: [channel.name]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [{user.pid, ":irc.test 315 #{user.nick} #{channel.name} :End of WHO list\r\n"}],
          validate_order?: false
        )
      end)
    end

    test "handles WHO command with mask target and user shares channel" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "anick1")
        channel = insert(:channel)
        insert(:user_channel, channel: channel, user: user)

        another_user1 = insert(:user, nick: "anick2", modes: ["o"])
        another_user2 = insert(:user, nick: "anick3", modes: ["o"])
        another_user3 = insert(:user, nick: "anick4", modes: ["i"])
        another_user4 = insert(:user, nick: "anick5", away_message: "away")
        insert(:user_channel, channel: channel, user: another_user1)
        insert(:user_channel, channel: channel, user: another_user2, modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user3, modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user4, modes: ["v"])

        message = %Message{command: "WHO", params: ["anick*"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.pid,
             ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{another_user1.nick} H* :0 realname\r\n"},
            {user.pid,
             ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{another_user2.nick} H* :0 realname\r\n"},
            {user.pid,
             ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{another_user3.nick} H :0 realname\r\n"},
            {user.pid,
             ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{another_user4.nick} G :0 realname\r\n"},
            {user.pid, ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{user.nick} H :0 realname\r\n"},
            {user.pid, ":irc.test 315 #{user.nick} anick* :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "handles WHO command with mask target and user does not share channel" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "anick1")
        channel = insert(:channel)

        another_user1 = insert(:user, nick: "anick2", modes: ["o"])
        another_user2 = insert(:user, nick: "anick3", modes: ["o"])
        another_user3 = insert(:user, nick: "anick4", modes: ["i"])
        another_user4 = insert(:user, nick: "anick5", away_message: "away")
        insert(:user_channel, channel: channel, user: another_user1)
        insert(:user_channel, channel: channel, user: another_user2, modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user3, modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user4, modes: ["v"])

        message = %Message{command: "WHO", params: ["anick*"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.pid,
             ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{another_user1.nick} H* :0 realname\r\n"},
            {user.pid,
             ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{another_user2.nick} H* :0 realname\r\n"},
            {user.pid,
             ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{another_user4.nick} G :0 realname\r\n"},
            {user.pid, ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{user.nick} H :0 realname\r\n"},
            {user.pid, ":irc.test 315 #{user.nick} anick* :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "handles WHO command with mask target and user shares secret channel" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "anick1")
        channel = insert(:channel, modes: ["s"])
        insert(:user_channel, channel: channel, user: user)

        another_user1 = insert(:user, nick: "anick2")
        another_user2 = insert(:user, nick: "anick3", modes: ["i"])
        insert(:user_channel, channel: channel, user: another_user1)
        insert(:user_channel, channel: channel, user: another_user2)

        message = %Message{command: "WHO", params: ["anick*"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.pid,
             ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{another_user1.nick} H :0 realname\r\n"},
            {user.pid,
             ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{another_user2.nick} H :0 realname\r\n"},
            {user.pid, ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{user.nick} H :0 realname\r\n"},
            {user.pid, ":irc.test 315 #{user.nick} anick* :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "handles WHO command with mask target, user shares channel and resolves channel name visibility" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)
        insert(:user_channel, channel: channel, user: user)

        another_user1 = insert(:user, nick: "anick2", modes: ["i", "o"])
        insert(:user_channel, channel: channel, user: another_user1, modes: ["o"])

        message = %Message{command: "WHO", params: ["anick*"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 352 #{user.nick} #{channel.name} #{user.ident} hostname irc.test #{another_user1.nick} H*@ :0 realname\r\n"},
          {user.pid, ":irc.test 315 #{user.nick} anick* :End of WHO list\r\n"}
        ])
      end)
    end

    test "handles WHO command with mask target, user does not share channel and resolves channel name visibility" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)

        another_user1 = insert(:user, nick: "anick2", modes: ["o"])
        insert(:user_channel, channel: channel, user: another_user1, modes: ["o"])

        message = %Message{command: "WHO", params: ["anick*"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 352 #{user.nick} #{channel.name} #{user.ident} hostname irc.test #{another_user1.nick} H*@ :0 realname\r\n"},
          {user.pid, ":irc.test 315 #{user.nick} anick* :End of WHO list\r\n"}
        ])
      end)
    end

    test "handles WHO command with mask target, user does not share channel and does not resolve channel name visibility" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["s"])

        another_user1 = insert(:user, nick: "anick2")
        insert(:user_channel, channel: channel, user: another_user1, modes: ["o"])

        message = %Message{command: "WHO", params: ["anick*"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{another_user1.nick} H :0 realname\r\n"},
          {user.pid, ":irc.test 315 #{user.nick} anick* :End of WHO list\r\n"}
        ])
      end)
    end

    test "handles WHO command with mask target and operator filter" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "anick1")
        channel = insert(:channel)
        insert(:user_channel, channel: channel, user: user)

        another_user = insert(:user, nick: "anick2", modes: ["o"])
        insert(:user, nick: "anick3", modes: [])

        message = %Message{command: "WHO", params: ["*", "o"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{another_user.nick} H* :0 realname\r\n"},
          {user.pid, ":irc.test 315 #{user.nick} * :End of WHO list\r\n"}
        ])
      end)
    end

    test "handles WHO command with channel target and operator filter" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)
        insert(:user_channel, channel: channel, user: user)

        another_user1 = insert(:user, modes: ["o"])
        another_user2 = insert(:user, modes: [])
        insert(:user_channel, channel: channel, user: another_user1)
        insert(:user_channel, channel: channel, user: another_user2, modes: ["o"])

        message = %Message{command: "WHO", params: [channel.name, "o"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 352 #{user.nick} #{channel.name} #{user.ident} hostname irc.test #{another_user1.nick} H* :0 realname\r\n"},
          {user.pid, ":irc.test 315 #{user.nick} #{channel.name} :End of WHO list\r\n"}
        ])
      end)
    end

    test "handles WHO command with mask target for user with no channels" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "testuser")
        target_user = insert(:user, nick: "anick2", modes: ["o"])

        message = %Message{command: "WHO", params: ["anick*"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{target_user.nick} H* :0 realname\r\n"},
          {user.pid, ":irc.test 315 #{user.nick} anick* :End of WHO list\r\n"}
        ])
      end)
    end

    test "handles WHO command with mask target and orphaned channel reference (edge case)" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "testuser")
        target_user = insert(:user, nick: "anick2")

        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel)

        # Delete the channel to create an orphaned reference
        Memento.Query.delete_record(channel)

        message = %Message{command: "WHO", params: ["anick*"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{target_user.nick} H :0 realname\r\n"},
          {user.pid, ":irc.test 315 #{user.nick} anick* :End of WHO list\r\n"}
        ])
      end)
    end

    for {fields, numeric, trailing} <- [{nil, "352", " :0 realname"}, {"%nf", "354", ""}],
        {capabilities, prefix} <- [{[], "@"}, {["multi-prefix"], "@+"}],
        requester_modes <- [[], ["o"]] do
      test "WHO flags #{inspect({fields, capabilities, requester_modes})} exclude user modes and respect multi-prefix" do
        Memento.transaction!(fn ->
          user = insert(:user, capabilities: unquote(capabilities), modes: unquote(requester_modes))
          channel = insert(:channel)
          insert(:user_channel, channel: channel, user: user)
          target = insert(:user, nick: "target", modes: ["o", "i", "w"], away_message: "Away")
          insert(:user_channel, channel: channel, user: target, modes: ["v", "o"])

          params = [target.nick] ++ List.wrap(unquote(fields))
          assert :ok = Who.handle(user, %Message{command: "WHO", params: params})

          detail =
            if unquote(numeric) == "352",
              do: "#{channel.name} #{target.ident} hostname irc.test ",
              else: ""

          assert_sent_messages([
            {user.pid,
             ":irc.test #{unquote(numeric)} #{user.nick} #{detail}#{target.nick} G*#{unquote(prefix)}#{unquote(trailing)}\r\n"},
            {user.pid, ":irc.test 315 #{user.nick} #{target.nick} :End of WHO list\r\n"}
          ])
        end)
      end
    end

    test "WHOX uses canonical field order and logged-out placeholders without CAP negotiation" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        target = insert(:user, nick: "target", identified_as: nil)

        assert :ok = Who.handle(user, %Message{command: "WHO", params: [target.nick, "%aanict?,009"]})

        # Request order, duplicates and unknown fields do not change the canonical wire order.
        assert_sent_messages([
          {user.pid, ":irc.test 354 #{user.nick} 009 * 255.255.255.255 target 0\r\n"},
          {user.pid, ":irc.test 315 #{user.nick} #{target.nick} :End of WHO list\r\n"}
        ])
      end)
    end

    test "handles WHOX command with common o% filter syntax and token" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "requester")
        channel = insert(:channel)
        insert(:user_channel, channel: channel, user: user)

        target_user =
          insert(:user,
            nick: "oper_target",
            ident: "~oper",
            hostname: "oper.example.test",
            realname: "Oper Target",
            modes: ["o"],
            identified_as: "oper_account",
            last_activity: :erlang.system_time(:second) + 60
          )

        insert(:user_channel, channel: channel, user: target_user, modes: ["o"])
        insert(:user, nick: "non_oper_target")

        message = %Message{command: "WHO", params: [channel.name, "o%tcuihsnfdlar,42"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 354 #{user.nick} 42 #{channel.name} #{target_user.ident} 255.255.255.255 #{target_user.hostname} irc.test #{target_user.nick} H*@ 0 0 #{target_user.identified_as} :#{target_user.realname}\r\n"},
          {user.pid, ":irc.test 315 #{user.nick} #{channel.name} :End of WHO list\r\n"}
        ])
      end)
    end

    test "handles WHOX command returning real IP and channel level to operators" do
      Memento.transaction!(fn ->
        operator_user = insert(:user, nick: "oper_requester", modes: ["o"])
        channel = insert(:channel)
        insert(:user_channel, channel: channel, user: operator_user)

        target_user =
          insert(:user,
            nick: "voice_target",
            ip_address: {192, 0, 2, 10}
          )

        insert(:user_channel, channel: channel, user: target_user, modes: ["v"])

        message = %Message{command: "WHO", params: [channel.name, "%tio,7"]}
        assert :ok = Who.handle(operator_user, message)

        assert_sent_messages(
          [
            {operator_user.pid, ":irc.test 354 #{operator_user.nick} 7 127.0.0.1 0\r\n"},
            {operator_user.pid, ":irc.test 354 #{operator_user.nick} 7 192.0.2.10 1\r\n"},
            {operator_user.pid, ":irc.test 315 #{operator_user.nick} #{channel.name} :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "handles WHOX command without token and reports channel operator level" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "requester")
        channel = insert(:channel)
        insert(:user_channel, channel: channel, user: user)

        target_user = insert(:user, nick: "channel_oper")
        insert(:user_channel, channel: channel, user: target_user, modes: ["o"])

        message = %Message{command: "WHO", params: [channel.name, "%to"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.pid, ":irc.test 354 #{user.nick} 0\r\n"},
            {user.pid, ":irc.test 354 #{user.nick} 2\r\n"},
            {user.pid, ":irc.test 315 #{user.nick} #{channel.name} :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "handles WHOX command with empty token and no visible channel" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "requester")
        target_user = insert(:user, nick: "lonely_user")

        message = %Message{command: "WHO", params: [target_user.nick, "%to,"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 354 #{user.nick} 0\r\n"},
          {user.pid, ":irc.test 315 #{user.nick} #{target_user.nick} :End of WHO list\r\n"}
        ])
      end)
    end

    test "falls back to standard WHO replies when WHOX support is disabled" do
      original_whox = Application.get_env(:elixircd, :whox)
      on_exit(fn -> Application.put_env(:elixircd, :whox, original_whox) end)

      Application.put_env(
        :elixircd,
        :whox,
        (original_whox || [])
        |> Keyword.put(:enabled, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user, nick: "requester")
        channel = insert(:channel)
        insert(:user_channel, channel: channel, user: user)

        target_user =
          insert(:user,
            nick: "oper_target",
            ident: "~oper",
            hostname: "oper.example.test",
            realname: "Oper Target",
            modes: ["o"]
          )

        insert(:user_channel, channel: channel, user: target_user, modes: ["o"])

        message = %Message{command: "WHO", params: [channel.name, "o%tcuihsnfdlar,42"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 352 #{user.nick} #{channel.name} #{target_user.ident} #{target_user.hostname} irc.test #{target_user.nick} H*@ :0 #{target_user.realname}\r\n"},
          {user.pid, ":irc.test 315 #{user.nick} #{channel.name} :End of WHO list\r\n"}
        ])
      end)
    end

    test "does not filter operators when WHOX is disabled and query contains field o without o flag" do
      original_whox = Application.get_env(:elixircd, :whox)
      on_exit(fn -> Application.put_env(:elixircd, :whox, original_whox) end)

      Application.put_env(
        :elixircd,
        :whox,
        (original_whox || [])
        |> Keyword.put(:enabled, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user, nick: "requester")
        channel = insert(:channel)
        insert(:user_channel, channel: channel, user: user)

        regular_user =
          insert(:user,
            nick: "regular",
            ident: "~user",
            hostname: "user.example.test",
            realname: "Regular User",
            modes: []
          )

        insert(:user_channel, channel: channel, user: regular_user)

        message = %Message{command: "WHO", params: [channel.name, "%to,7"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.pid,
             ":irc.test 352 #{user.nick} #{channel.name} #{user.ident} #{user.hostname} irc.test #{user.nick} H :0 #{user.realname}\r\n"},
            {user.pid,
             ":irc.test 352 #{user.nick} #{channel.name} #{regular_user.ident} #{regular_user.hostname} irc.test #{regular_user.nick} H :0 #{regular_user.realname}\r\n"},
            {user.pid, ":irc.test 315 #{user.nick} #{channel.name} :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "does not filter operators when parameter contains letter o but is not the o flag" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "requester")
        regular_user = insert(:user, nick: "nonoper", modes: [])

        message = %Message{command: "WHO", params: ["nonoper*", "root"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 352 #{user.nick} * #{regular_user.ident} hostname irc.test #{regular_user.nick} H :0 realname\r\n"},
          {user.pid, ":irc.test 315 #{user.nick} nonoper* :End of WHO list\r\n"}
        ])
      end)
    end

    test "handles WHO 0 by listing all visible users" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target = insert(:user, nick: "whoz_target")

        message = %Message{command: "WHO", params: ["0"]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages(
          [
            {user.pid, ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{user.nick} H :0 realname\r\n"},
            {user.pid,
             ":irc.test 352 #{user.nick} * #{target.ident} hostname irc.test #{target.nick} H :0 realname\r\n"},
            {user.pid, ":irc.test 315 #{user.nick} 0 :End of WHO list\r\n"}
          ],
          validate_order?: false
        )
      end)
    end

    test "allows direct private channel queries while filtering invisible users" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["p"])
        target = insert(:user, nick: "priv_target")
        insert(:user_channel, channel: channel, user: target)

        invisible = insert(:user, nick: "hidden", modes: ["i"])
        insert(:user_channel, user: invisible, channel: channel)

        message = %Message{command: "WHO", params: [channel.name]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 352 #{user.nick} #{channel.name} #{target.ident} hostname irc.test #{target.nick} H :0 realname\r\n"},
          {user.pid, ":irc.test 315 #{user.nick} #{channel.name} :End of WHO list\r\n"}
        ])
      end)
    end

    test "always shows the requesting user in WHO mask queries despite +i" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["i"])

        message = %Message{command: "WHO", params: [user.nick]}
        assert :ok = Who.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 352 #{user.nick} * #{user.ident} hostname irc.test #{user.nick} H :0 realname\r\n"},
          {user.pid, ":irc.test 315 #{user.nick} #{user.nick} :End of WHO list\r\n"}
        ])
      end)
    end
  end

  test "the invisible self exception preserves mask and operator filters" do
    Memento.transaction!(fn ->
      user = insert(:user, modes: ["i"], nick: "InvisibleSelf")

      for params <- [["NobodyMatches*"], [user.nick, "o"]] do
        Who.handle(user, %Message{command: "WHO", params: params})
        assert_sent_messages_count_containing(user.pid, ~r/ 352 /, 0)
        assert_sent_messages_amount(user.pid, 1)
      end
    end)
  end

  test "sharing a public channel does not reveal the target's private memberships" do
    Memento.transaction!(fn ->
      user = insert(:user)
      target = insert(:user, nick: "PrivateMember")
      public = insert(:channel, name: "#public")
      private = insert(:channel, name: "#private", modes: ["p"])
      for member <- [user, target], do: insert(:user_channel, user: member, channel: public)
      insert(:user_channel, user: target, channel: private)
      Who.handle(user, %Message{command: "WHO", params: [target.nick]})
      assert_sent_messages_count_containing(user.pid, ~r/ 352 .* #private /, 0)
      assert_sent_messages_count_containing(user.pid, ~r/ 352 .* #public /, 1)
    end)
  end
end
