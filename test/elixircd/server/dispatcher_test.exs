defmodule ElixIRCd.Server.DispatcherTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Server.Dispatcher

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

    test "broadcasts with User context, adding prefix and bot tag for bot user", %{
      message: message
    } do
      bot_user = insert(:user, nick: "botuser", ident: "bot", hostname: "bot.host", modes: ["B"])
      target_with_caps = insert(:user, capabilities: ["MESSAGE-TAGS"])
      expected_message = "@bot :botuser!bot@bot.host PRIVMSG #test :hello\r\n"

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === target_with_caps.pid
        assert received_message == expected_message
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
      bot_user = insert(:user, nick: "botuser", ident: "bot", hostname: "bot.host", modes: ["B"])
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
      user_with_caps = insert(:user, capabilities: ["MESSAGE-TAGS"])

      message_with_tags =
        %Message{command: "NOTICE", params: ["test"], trailing: "hello"}
        |> Map.put(:tags, %{"bot" => nil})

      expected_with_tags = "@bot :irc.test NOTICE test :hello\r\n"

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === user_with_caps.pid
        assert received_message == expected_with_tags
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
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        original_config
        |> Keyword.put(:server_time, true)
        |> Keyword.put(:msgid, true)
      )

      user_with_caps = insert(:user, capabilities: ["MESSAGE-TAGS", "SERVER-TIME", "MSGID"])
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

    test "adds account tag when sender is identified and recipient has ACCOUNT-TAG" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || [])
        |> Keyword.put(:account_tag, true)
      )

      sender = insert(:user, nick: "acctuser", ident: "acct", hostname: "acct.host", identified_as: "account_name")
      recipient_with_cap = insert(:user, capabilities: ["MESSAGE-TAGS", "ACCOUNT-TAG"])
      recipient_without_cap = insert(:user, capabilities: ["MESSAGE-TAGS"])

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

    test "does not add msgid tag when MSGID capability is not negotiated" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || [])
        |> Keyword.put(:msgid, true)
      )

      user_without_msgid = insert(:user, capabilities: ["MESSAGE-TAGS"])
      message = %Message{command: "NOTICE", params: ["test"], trailing: "hello"}

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === user_without_msgid.pid
        # Continua sem msgid= pois o usuário não negociou MSGID.
        refute String.contains?(received_message, "msgid=")
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message, :server, user_without_msgid)

      Connection
      |> reject(:handle_send, 2)
    end

    test "strips msgid tag when MSGID capability is disabled in config" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || [])
        |> Keyword.put(:msgid, false)
      )

      user_with_caps = insert(:user, capabilities: ["MESSAGE-TAGS", "MSGID"])

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
      recipient = insert(:user, capabilities: ["MESSAGE-TAGS", "ACCOUNT-TAG"])

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
