defmodule ElixIRCd.Server.DispatcherTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.ResponseContext
  alias ElixIRCd.StandardReply

  describe "broadcast/3 with context" do
    setup do
      user = insert(:user, nick: "testnick", ident: "testident", hostname: "test.host")
      target_user = insert(:user)
      message = %Message{command: "PRIVMSG", params: ["#test"], trailing: "hello"}

      {:ok,
       %{
         user: user,
         target_user: target_user,
         message: message
       }}
    end

    test "delivers extension replies without standard-replies and preserves service correlation" do
      for capabilities <- [["batch", "labeled-response"], ["setname", "batch", "labeled-response"]] do
        user = insert(:user, capabilities: capabilities)
        reply = %StandardReply{type: :fail, command: "SETNAME", code: "INVALID_REALNAME", description: "Invalid"}
        request = %Message{command: "SETNAME", params: [], tags: %{"label" => "extension"}}

        setup_expectations([
          {user.pid, "@label=extension :NickServ!service@irc.test FAIL SETNAME INVALID_REALNAME :Invalid\r\n"}
        ])

        ResponseContext.with_command(user, request, fn ->
          assert :ok = Dispatcher.broadcast(reply, :nickserv, user)
        end)
      end
    end

    test "bounds standard replies with a service prefix without splitting UTF-8 or counting tags" do
      user = insert(:user, capabilities: ["standard-replies", "server-time"])
      message = %Message{command: "WARN", params: ["*", "LONG", "context"], trailing: String.duplicate("🌍", 200)}

      Connection
      |> expect(:handle_send, fn pid, wire ->
        assert pid == user.pid
        assert String.valid?(wire)
        [tags, body] = String.split(wire, " ", parts: 2)
        assert String.starts_with?(tags, "@time=")
        assert byte_size(body) <= 512
        assert byte_size(body) >= 509
        assert body =~ ":NickServ!service@irc.test WARN * LONG context :"
        :ok
      end)

      assert :ok = Dispatcher.broadcast(message, :nickserv, user)
    end

    test "delivers a standard reply description parsed as a middle parameter for every reply type" do
      user = insert(:user, capabilities: ["standard-replies"])

      for type <- ["FAIL", "WARN", "NOTE"] do
        message = Message.parse!(":irc.test #{type} EXAMPLE CODE #context Description")
        assert message.trailing == nil

        Connection
        |> expect(:handle_send, fn pid, wire ->
          assert pid == user.pid
          assert wire == ":irc.test #{type} EXAMPLE CODE #context :Description\r\n"
          :ok
        end)

        assert :ok = Dispatcher.broadcast(message, :server, user)
      end
    end

    test "broadcasts with User context, adding prefix and bot tag for bot user", %{
      message: message
    } do
      bot_user = insert(:user, nick: "botuser", ident: "bot", hostname: "bot.host", modes: [:B])
      target_with_caps = insert(:user, capabilities: ["message-tags"])
      expected_message = ~r/^@bot;msgid=[A-Za-z0-9_-]{24} :botuser!bot@bot\.host PRIVMSG #test :hello\r\n$/

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === target_with_caps.pid
        assert received_message =~ expected_message
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, bot_user, target_with_caps)

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts with User context, bot tag filtered for user without MESSAGE-TAGS capability", %{
      message: message,
      target_user: target_user
    } do
      bot_user = insert(:user, nick: "botuser", ident: "bot", hostname: "bot.host", modes: [:B])
      expected_message = ":botuser!bot@bot.host PRIVMSG #test :hello\r\n"

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === target_user.pid
        assert received_message == expected_message
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, bot_user, target_user)

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts with User context, adding prefix without bot tag for regular user", %{
      user: user,
      message: message,
      target_user: target_user
    } do
      expected_message = ":testnick!testident@test.host PRIVMSG #test :hello\r\n"

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === target_user.pid
        assert received_message == expected_message
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, user, target_user)

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts with :server context, adding server prefix", %{
      message: message,
      target_user: target_user
    } do
      expected_message = ":irc.test PRIVMSG #test :hello\r\n"

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === target_user.pid
        assert received_message == expected_message
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, :server, target_user)

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts with nil context without adding a prefix", %{message: message, target_user: target_user} do
      expected_message = "PRIVMSG #test :hello\r\n"

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === target_user.pid
        assert received_message == expected_message
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, nil, target_user)

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts with User context to a pid target that is not the sender", %{user: user, message: message} do
      target_pid = self()

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === target_pid
        parsed = Message.parse!(received_message)
        assert parsed.prefix == "testnick!testident@test.host"
        assert parsed.command == "PRIVMSG"
        assert parsed.params == ["#test"]
        assert parsed.trailing == "hello"
        assert is_binary(parsed.tags["msgid"])
        assert is_binary(parsed.tags["time"])
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, user, target_pid)

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts with User context to the sender pid target using user capabilities", %{
      user: user,
      message: message
    } do
      sender_with_caps = %{user | capabilities: ["message-tags"], modes: [:B]}

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === sender_with_caps.pid
        parsed = Message.parse!(received_message)
        assert parsed.prefix == "testnick!testident@test.host"
        assert parsed.command == "PRIVMSG"
        assert parsed.params == ["#test"]
        assert parsed.trailing == "hello"
        assert parsed.tags["bot"] == nil
        assert is_binary(parsed.tags["msgid"])
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, sender_with_caps, sender_with_caps.pid)

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts with User context to multiple targets", %{
      user: user,
      target_user: target_user
    } do
      another_user = insert(:user)
      message = %Message{command: "JOIN", params: ["#channel"]}
      expected_message = ":testnick!testident@test.host JOIN #channel\r\n"

      Connection
      |> expect(:handle_send, 2, fn pid, received_message ->
        assert pid in [target_user.pid, another_user.pid]
        assert received_message == expected_message
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, user, [target_user, another_user])

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts multiple messages with User context to single target", %{
      user: user,
      target_user: target_user
    } do
      message1 = %Message{command: "PRIVMSG", params: ["#test"], trailing: "hello"}
      message2 = %Message{command: "PRIVMSG", params: ["#test"], trailing: "world"}

      expected_message1 = ":testnick!testident@test.host PRIVMSG #test :hello\r\n"
      expected_message2 = ":testnick!testident@test.host PRIVMSG #test :world\r\n"

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === target_user.pid
        assert received_message == expected_message1
        :ok
      end)
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === target_user.pid
        assert received_message == expected_message2
        :ok
      end)

      assert :ok == Dispatcher.broadcast([message1, message2], user, target_user)

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts multiple messages with User context to multiple targets", %{
      user: user,
      target_user: target_user
    } do
      another_user = insert(:user)
      message1 = %Message{command: "PRIVMSG", params: ["#test"], trailing: "hello"}
      message2 = %Message{command: "PRIVMSG", params: ["#test"], trailing: "world"}

      expected_message1 = ":testnick!testident@test.host PRIVMSG #test :hello\r\n"
      expected_message2 = ":testnick!testident@test.host PRIVMSG #test :world\r\n"

      Connection
      |> expect(:handle_send, 4, fn pid, received_message ->
        assert pid in [target_user.pid, another_user.pid]
        assert received_message in [expected_message1, expected_message2]
        :ok
      end)

      assert :ok == Dispatcher.broadcast([message1, message2], user, [target_user, another_user])

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts with :chanserv context, adding ChanServ prefix", %{
      target_user: target_user
    } do
      message = %Message{command: "NOTICE", params: ["testnick"], trailing: "ChanServ message"}
      expected_message = ":ChanServ!service@irc.test NOTICE testnick :ChanServ message\r\n"

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === target_user.pid
        assert received_message == expected_message
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, :chanserv, target_user)

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts multiple messages with :chanserv context to single target", %{
      target_user: target_user
    } do
      message1 = %Message{command: "NOTICE", params: ["testnick"], trailing: "Message 1"}
      message2 = %Message{command: "NOTICE", params: ["testnick"], trailing: "Message 2"}

      expected_message1 = ":ChanServ!service@irc.test NOTICE testnick :Message 1\r\n"
      expected_message2 = ":ChanServ!service@irc.test NOTICE testnick :Message 2\r\n"

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === target_user.pid
        assert received_message == expected_message1
        :ok
      end)
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === target_user.pid
        assert received_message == expected_message2
        :ok
      end)

      assert :ok == Dispatcher.broadcast([message1, message2], :chanserv, target_user)

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts with :nickserv context, adding NickServ prefix", %{
      target_user: target_user
    } do
      message = %Message{command: "NOTICE", params: ["testnick"], trailing: "NickServ message"}
      expected_message = ":NickServ!service@irc.test NOTICE testnick :NickServ message\r\n"

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === target_user.pid
        assert received_message == expected_message
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, :nickserv, target_user)

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts multiple messages with :nickserv context to single target", %{
      target_user: target_user
    } do
      message1 = %Message{command: "NOTICE", params: ["testnick"], trailing: "Message 1"}
      message2 = %Message{command: "NOTICE", params: ["testnick"], trailing: "Message 2"}

      expected_message1 = ":NickServ!service@irc.test NOTICE testnick :Message 1\r\n"
      expected_message2 = ":NickServ!service@irc.test NOTICE testnick :Message 2\r\n"

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === target_user.pid
        assert received_message == expected_message1
        :ok
      end)
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === target_user.pid
        assert received_message == expected_message2
        :ok
      end)

      assert :ok == Dispatcher.broadcast([message1, message2], :nickserv, target_user)

      Connection
      |> reject(:handle_send, 2)
    end
  end

  describe "broadcast/3 - various target types" do
    setup do
      user = insert(:user)
      pid = self()
      message = %Message{command: "PING", params: ["target"]}
      raw_message = ":irc.test PING target\r\n"

      {:ok,
       %{
         user: user,
         pid: pid,
         message: message,
         raw_message: raw_message
       }}
    end

    test "broadcasts mixed messages and standard replies to user and PID targets", %{user: user, pid: pid} do
      message = %Message{command: :rpl_rehashing, params: [user.nick, "elixircd.exs"], trailing: "Rehashing"}

      reply = %StandardReply{
        type: :note,
        command: "REHASH",
        code: "REHASH_COMPLETE",
        description: "Rehashing completed"
      }

      setup_expectations([
        {user.pid, ":irc.test 382 #{user.nick} elixircd.exs :Rehashing\r\n"},
        {pid, ":irc.test 382 #{user.nick} elixircd.exs :Rehashing\r\n"},
        {user.pid, ":irc.test NOTE REHASH REHASH_COMPLETE :Rehashing completed\r\n"},
        {pid, ":irc.test NOTE REHASH REHASH_COMPLETE :Rehashing completed\r\n"}
      ])

      assert :ok = Dispatcher.broadcast([message, reply], :server, [user, pid])
    end

    test "broadcasts a single message to a single target", %{
      user: user,
      pid: pid,
      message: message,
      raw_message: raw_message
    } do
      test_cases = [
        {message, user, user.pid},
        {message, pid, pid}
      ]

      for {msg, target, expected_pid} <- test_cases do
        setup_expectations([{expected_pid, raw_message}])
        assert :ok == Dispatcher.broadcast(msg, :server, target)
      end

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts a single message to multiple targets", %{
      user: user,
      pid: pid,
      message: message,
      raw_message: raw_message
    } do
      setup_expectations([
        {user.pid, raw_message},
        {pid, raw_message}
      ])

      assert :ok == Dispatcher.broadcast(message, :server, [user, pid])

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts multiple messages to a single target", %{
      user: user,
      pid: pid,
      message: message,
      raw_message: raw_message
    } do
      test_cases = [
        {user, user.pid},
        {pid, pid}
      ]

      for {target, expected_pid} <- test_cases do
        Connection
        |> expect(:handle_send, 2, fn pid, received_message ->
          assert pid === expected_pid
          assert received_message == raw_message
          :ok
        end)

        assert :ok == Dispatcher.broadcast([message, message], :server, target)
      end

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts multiple messages to multiple targets", %{
      user: user,
      pid: pid,
      message: message,
      raw_message: raw_message
    } do
      for _ <- 1..2 do
        setup_expectations([
          {user.pid, raw_message},
          {pid, raw_message}
        ])
      end

      assert :ok == Dispatcher.broadcast([message, message], :server, [user, pid])

      Connection
      |> reject(:handle_send, 2)
    end

    test "filters message tags based on recipient capabilities with :server context", %{user: _user} do
      user_with_caps = insert(:user, capabilities: ["message-tags"])

      message_with_tags =
        %Message{command: "NOTICE", params: ["test"], trailing: "hello"}
        |> Map.put(:tags, %{"bot" => nil})

      expected_with_tags = ~r/^@bot;msgid=[A-Za-z0-9_-]{24} :irc\.test NOTICE test :hello\r\n$/

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === user_with_caps.pid
        assert received_message =~ expected_with_tags
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message_with_tags, :server, user_with_caps)

      user_without_caps = insert(:user, capabilities: [])

      expected_without_tags = ":irc.test NOTICE test :hello\r\n"

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === user_without_caps.pid
        assert received_message == expected_without_tags
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message_with_tags, :server, user_without_caps)

      Connection
      |> reject(:handle_send, 2)
    end

    test "adds server time and msgid tags when capabilities are enabled" do
      user_with_caps = insert(:user, capabilities: ["message-tags", "server-time"])
      message = %Message{command: "NOTICE", params: ["test"], trailing: "hello"}

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === user_with_caps.pid
        assert String.starts_with?(received_message, "@")
        assert String.contains?(received_message, "time=")
        assert String.contains?(received_message, "msgid=")
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, :server, user_with_caps)

      Connection
      |> reject(:handle_send, 2)
    end

    test "adds server time when SERVER-TIME is negotiated without MESSAGE-TAGS" do
      user_with_caps = insert(:user, capabilities: ["server-time"])
      message = %Message{command: "NOTICE", params: ["test"], trailing: "hello"}

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === user_with_caps.pid
        assert String.starts_with?(received_message, "@time=")
        assert String.contains?(received_message, " :irc.test NOTICE test :hello\r\n")
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, :server, user_with_caps)

      Connection
      |> reject(:handle_send, 2)
    end

    test "filters client-only tags when recipient has SERVER-TIME without MESSAGE-TAGS" do
      sender = insert(:user, capabilities: ["message-tags"])
      recipient = insert(:user, capabilities: ["server-time"])

      message = %Message{
        command: "PRIVMSG",
        params: [recipient.nick],
        trailing: "hello",
        tags: %{"+draft/reply" => "123"}
      }

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === recipient.pid
        assert String.starts_with?(received_message, "@time=")
        refute received_message =~ "+draft/reply"
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, sender, recipient)

      Connection
      |> reject(:handle_send, 2)
    end

    test "adds account tag when sender is identified and recipient has ACCOUNT-TAG" do
      sender = insert(:user, nick: "acctuser", ident: "acct", hostname: "acct.host", identified_as: "account_name")
      recipient_with_cap = insert(:user, capabilities: ["message-tags", "account-tag"])
      recipient_without_cap = insert(:user, capabilities: ["message-tags"])

      message = %Message{command: "NOTICE", params: ["test"], trailing: "hello"}

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === recipient_with_cap.pid
        assert String.starts_with?(received_message, "@")
        assert String.contains?(received_message, "account=account_name")
        :ok
      end)
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === recipient_without_cap.pid
        refute String.contains?(received_message, "account=")
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, sender, [recipient_with_cap, recipient_without_cap])

      Connection
      |> reject(:handle_send, 2)
    end

    test "adds account tag when recipient has ACCOUNT-TAG without MESSAGE-TAGS" do
      sender = insert(:user, nick: "acctuser", ident: "acct", hostname: "acct.host", identified_as: "account_name")
      recipient = insert(:user, capabilities: ["account-tag"])
      message = %Message{command: "NOTICE", params: ["test"], trailing: "hello"}

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === recipient.pid
        assert received_message == "@account=account_name :acctuser!acct@acct.host NOTICE test :hello\r\n"
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, sender, recipient)

      Connection
      |> reject(:handle_send, 2)
    end

    test "does not add msgid tags without MESSAGE-TAGS" do
      user_without_msgid = insert(:user, capabilities: ["server-time"])
      message = %Message{command: "NOTICE", params: ["test"], trailing: "hello"}

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === user_without_msgid.pid
        refute String.contains?(received_message, "msgid=")
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, :server, user_without_msgid)

      Connection
      |> reject(:handle_send, 2)
    end

    test "adds msgid tags with MESSAGE-TAGS alone" do
      user_with_caps = insert(:user, capabilities: ["message-tags"])
      message = %Message{command: "NOTICE", params: ["test"], trailing: "hello"}

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === user_with_caps.pid
        assert String.starts_with?(received_message, "@msgid=")
        assert String.contains?(received_message, " :irc.test NOTICE test :hello\r\n")
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, :server, user_with_caps)

      Connection
      |> reject(:handle_send, 2)
    end

    test "generates distinct IDs and preserves trusted IDs on retransmission" do
      user = insert(:user, capabilities: ["message-tags"])
      message = %Message{command: "PRIVMSG", params: [user.nick], trailing: "hello"}
      parent = self()

      expect(Connection, :handle_send, 3, fn _pid, wire ->
        send(parent, {:message_id, Message.parse!(wire).tags["msgid"]})
        :ok
      end)

      assert :ok = Dispatcher.broadcast(message, :server, user)
      assert_receive {:message_id, first}
      assert first =~ ~r/^[A-Za-z0-9_-]{24}$/
      assert :ok = Dispatcher.broadcast(message, :server, user)
      assert_receive {:message_id, second}
      assert second =~ ~r/^[A-Za-z0-9_-]{24}$/
      refute first == second
      assert :ok = Dispatcher.broadcast(%{message | tags: %{"msgid" => first}}, :server, user)
      assert_receive {:message_id, ^first}
    end

    test "filters message IDs for recipients without MESSAGE-TAGS in a mixed broadcast" do
      tagged = insert(:user, capabilities: ["message-tags"])
      untagged = insert(:user, capabilities: ["server-time"])
      message = %Message{command: "NOTICE", params: ["#test"], trailing: "hello"}

      expect(Connection, :handle_send, fn pid, wire ->
        assert pid == tagged.pid
        assert Message.parse!(wire).tags["msgid"] =~ ~r/^[A-Za-z0-9_-]{24}$/
        :ok
      end)

      expect(Connection, :handle_send, fn pid, wire ->
        assert pid == untagged.pid
        refute Map.has_key?(Message.parse!(wire).tags, "msgid")
        :ok
      end)

      assert :ok = Dispatcher.broadcast(message, :server, [tagged, untagged])
    end

    test "strips msgid tag when message IDs are disabled in config" do
      original_config = Application.get_env(:elixircd, :message_ids)
      on_exit(fn -> Application.put_env(:elixircd, :message_ids, original_config) end)

      Application.put_env(
        :elixircd,
        :message_ids,
        (original_config || [])
        |> Keyword.put(:enabled, false)
      )

      user_with_caps = insert(:user, capabilities: ["message-tags"])

      message = %Message{
        command: "NOTICE",
        params: ["test"],
        trailing: "hello",
        tags: %{"msgid" => "custom"}
      }

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === user_with_caps.pid
        refute String.contains?(received_message, "msgid=")
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, :server, user_with_caps)

      Connection
      |> reject(:handle_send, 2)
    end

    test "does not add account tag when account-tag config is disabled" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || [])
        |> Keyword.put(:account_tag, false)
      )

      sender = insert(:user, nick: "acctuser", ident: "acct", hostname: "acct.host", identified_as: "account_name")
      recipient = insert(:user, capabilities: ["message-tags", "account-tag"])

      message = %Message{command: "NOTICE", params: ["test"], trailing: "hello"}

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === recipient.pid
        refute String.contains?(received_message, "account=")
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, sender, recipient)

      Connection
      |> reject(:handle_send, 2)
    end
  end

  describe "broadcast_standard_reply/4" do
    test "selects exactly one optional reply according to each recipient's standard-replies capability" do
      reply = %StandardReply{type: :fail, command: "REHASH", code: "CONFIG_BAD", description: "Invalid configuration"}

      for capabilities <- [["standard-replies"], [], ["setname"]] do
        user = insert(:user, capabilities: capabilities)
        fallback = %Message{command: "NOTICE", params: [user.nick], trailing: "Invalid configuration"}

        expected =
          if "standard-replies" in capabilities,
            do: ":irc.test FAIL REHASH CONFIG_BAD :Invalid configuration\r\n",
            else: ":irc.test NOTICE #{user.nick} :Invalid configuration\r\n"

        setup_expectations([{user.pid, expected}])
        assert :ok = Dispatcher.broadcast_standard_reply(reply, :server, user, fallback)
      end
    end

    test "retains the selected service prefix and label on legacy fallback" do
      user = insert(:user, capabilities: ["batch", "labeled-response"])
      reply = %StandardReply{type: :note, command: "PRIVMSG", code: "ACCOUNT_INFO", description: "Account information"}
      fallback = %Message{command: "NOTICE", params: [user.nick], trailing: "Account information"}
      request = %Message{command: "PRIVMSG", params: ["NickServ"], tags: %{"label" => "legacy"}}

      setup_expectations([
        {user.pid, "@label=legacy :NickServ!service@irc.test NOTICE #{user.nick} :Account information\r\n"}
      ])

      ResponseContext.with_command(user, request, fn ->
        assert :ok = Dispatcher.broadcast_standard_reply(reply, :nickserv, user, fallback)
      end)
    end

    test "service replies reach only the selected user and preserve labels and server-time" do
      requester = insert(:user, capabilities: ["standard-replies", "batch", "labeled-response", "server-time"])
      other = insert(:user, capabilities: ["standard-replies"])
      request = %Message{command: "PRIVMSG", params: ["NickServ"], tags: %{"label" => "request42"}}
      reply = %StandardReply{type: :note, command: "PRIVMSG", code: "ACCOUNT_INFO", description: "Account information"}
      fallback = %Message{command: "NOTICE", params: [requester.nick], trailing: "Account information"}
      requester_pid = requester.pid
      other_pid = other.pid
      parent = self()

      expect(Connection, :handle_send, 2, fn pid, wire ->
        send(parent, {:delivered, pid, wire})
        :ok
      end)

      ResponseContext.with_command(requester, request, fn ->
        Dispatcher.broadcast_standard_reply(reply, :nickserv, requester, fallback)
        Dispatcher.broadcast_standard_reply(reply, :chanserv, other, fallback)
      end)

      assert_receive {:delivered, ^requester_pid, requester_message}
      assert_receive {:delivered, ^other_pid, other_message}

      assert requester_message =~
               ~r/^@label=request42;time=\S+ :NickServ!service@irc.test NOTE PRIVMSG ACCOUNT_INFO :Account information\r\n$/

      assert other_message == ":ChanServ!service@irc.test NOTE PRIVMSG ACCOUNT_INFO :Account information\r\n"
    end
  end

  describe "broadcast_with_echo/3" do
    test "forwards client-only tags to all recipients with MESSAGE-TAGS and strips client-sent server tags" do
      sender =
        insert(:user,
          nick: "echoer",
          ident: "ident",
          hostname: "host.test",
          capabilities: ["echo-message", "message-tags"]
        )

      recipient = insert(:user, capabilities: ["message-tags"])
      sender_pid = sender.pid
      recipient_pid = recipient.pid
      parent = self()

      Connection
      |> expect(:handle_send, 2, fn pid, received_message ->
        send(parent, {:delivered, pid, received_message})
        :ok
      end)

      assert :ok ==
               Dispatcher.broadcast_with_echo(
                 %Message{
                   command: "PRIVMSG",
                   params: ["#test"],
                   trailing: "hello",
                   tags: %{"unknown-tag" => "abc", "msgid" => "forged", "+draft/reply" => "123"}
                 },
                 sender,
                 recipient
               )

      assert_receive {:delivered, ^sender_pid, sender_message}
      assert_receive {:delivered, ^recipient_pid, recipient_message}

      assert sender_message =~ "+draft/reply=123"
      assert recipient_message =~ "+draft/reply=123"
      refute sender_message =~ "unknown-tag=abc"
      refute recipient_message =~ "unknown-tag=abc"
      refute sender_message =~ "msgid=forged"
      refute recipient_message =~ "msgid=forged"
    end

    test "echoes to the sender and reuses the same msgid for all recipients" do
      sender =
        insert(:user,
          nick: "echoer",
          ident: "ident",
          hostname: "host.test",
          capabilities: ["echo-message", "message-tags"]
        )

      recipient = insert(:user, capabilities: ["message-tags"])
      sender_pid = sender.pid
      recipient_pid = recipient.pid
      parent = self()

      Connection
      |> expect(:handle_send, 2, fn pid, received_message ->
        send(parent, {:delivered, pid, received_message})
        :ok
      end)

      assert :ok ==
               Dispatcher.broadcast_with_echo(
                 %Message{command: "PRIVMSG", params: ["#test"], trailing: "hello"},
                 sender,
                 recipient
               )

      assert_receive {:delivered, ^sender_pid, sender_message}
      assert_receive {:delivered, ^recipient_pid, recipient_message}

      assert sender_message =~ ":echoer!ident@host.test PRIVMSG #test :hello\r\n"
      assert recipient_message =~ ":echoer!ident@host.test PRIVMSG #test :hello\r\n"

      [sender_msgid] = Regex.run(~r/msgid=([^ ;]+)/, sender_message, capture: :all_but_first)
      [recipient_msgid] = Regex.run(~r/msgid=([^ ;]+)/, recipient_message, capture: :all_but_first)

      assert sender_msgid == recipient_msgid
    end

    test "does not echo when ECHO-MESSAGE is not negotiated" do
      sender = insert(:user, nick: "echoer", ident: "ident", hostname: "host.test", capabilities: [])
      recipient = insert(:user)

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === recipient.pid
        assert received_message == ":echoer!ident@host.test NOTICE target :hello\r\n"
        :ok
      end)

      assert :ok ==
               Dispatcher.broadcast_with_echo(
                 %Message{command: "NOTICE", params: ["target"], trailing: "hello"},
                 sender,
                 recipient
               )

      Connection
      |> reject(:handle_send, 2)
    end

    test "delivers and separately echoes when the sender messages themself" do
      sender = insert(:user, nick: "echoer", ident: "ident", hostname: "host.test", capabilities: ["echo-message"])

      Connection
      |> expect(:handle_send, 2, fn pid, received_message ->
        assert pid === sender.pid
        assert received_message == ":echoer!ident@host.test NOTICE echoer :hello\r\n"
        :ok
      end)

      assert :ok ==
               Dispatcher.broadcast_with_echo(
                 %Message{command: "NOTICE", params: ["echoer"], trailing: "hello"},
                 sender,
                 sender.pid
               )
    end
  end

  describe "send_prepared_message/2" do
    test "removes an account tag prepared before the capability was disabled" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)
      Application.put_env(:elixircd, :capabilities, Keyword.put(original_config, :account_tag, false))
      user = build(:user, capabilities: ["message-tags", "account-tag"])
      message = %Message{command: "NOTICE", params: [user.nick], trailing: "hello", tags: %{"account" => "private"}}

      expect(Connection, :handle_send, fn pid, wire ->
        assert pid == user.pid
        assert wire == "NOTICE #{user.nick} :hello\r\n"
        :ok
      end)

      assert :ok = Dispatcher.send_prepared_message(message, user)
    end

    test "sends an enqueued prepared message immediately without an active batch" do
      user = build(:user, capabilities: ["batch"])
      message = %Message{command: "NOTICE", params: [user.nick], trailing: "hello"}

      expect(Connection, :handle_send, fn pid, wire ->
        assert pid == user.pid
        assert wire == "NOTICE #{user.nick} :hello\r\n"
        :ok
      end)

      assert :ok = Dispatcher.enqueue_prepared_message(message, user)
    end

    test "preserves a preexisting history timestamp" do
      sender = build(:user, nick: "sender")
      target = build(:user, nick: "target", capabilities: ["message-tags", "server-time"])
      timestamp = "2026-01-01T00:00:00.000Z"
      message = %Message{command: "PRIVMSG", params: [target.nick], trailing: "hello", tags: %{"time" => timestamp}}

      expect(Connection, :handle_send, fn pid, wire ->
        assert pid == target.pid
        assert wire =~ ";time="
        :ok
      end)

      assert :ok = Dispatcher.broadcast(message, sender, target)
    end
  end

  @spec setup_expectations(list({pid(), String.t()})) :: :ok
  defp setup_expectations(expectations) do
    for {expected_pid, expected_message} <- expectations do
      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === expected_pid
        assert received_message == expected_message
        :ok
      end)
    end
  end
end
