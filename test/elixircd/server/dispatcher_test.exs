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
      message = Message.build(%{command: "PRIVMSG", params: ["#test"], trailing: "hello"})

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

    test "broadcasts with User context, does not override existing prefix", %{
      user: user,
      target_user: target_user
    } do
      message_with_prefix =
        Message.build(%{prefix: "custom!user@host", command: "PRIVMSG", params: ["#test"], trailing: "hello"})

      expected_message = ":custom!user@host PRIVMSG #test :hello\r\n"

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === target_user.pid
        assert received_message == expected_message
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message_with_prefix, user, target_user)

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

    test "broadcasts with :server context, does not override existing prefix", %{
      target_user: target_user
    } do
      message_with_prefix =
        Message.build(%{prefix: "custom.server", command: "NOTICE", params: ["#test"], trailing: "notice"})

      expected_message = ":custom.server NOTICE #test :notice\r\n"

      Connection
      |> expect(:handle_send, fn pid, received_message ->
        assert pid === target_user.pid
        assert received_message == expected_message
        :ok
      end)

      assert :ok == Dispatcher.broadcast(message_with_prefix, :server, target_user)

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts with User context to multiple targets", %{
      user: user,
      target_user: target_user
    } do
      another_user = insert(:user)
      message = Message.build(%{command: "JOIN", params: ["#channel"]})
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
  end

  describe "broadcast/3 - various target types" do
    setup do
      user = insert(:user)
      user_channel = insert(:user_channel)
      pid = self()
      message = Message.build(%{command: "PING", params: ["target"]})
      raw_message = ":irc.test PING target\r\n"

      {:ok,
       %{
         user: user,
         user_channel: user_channel,
         pid: pid,
         message: message,
         raw_message: raw_message
       }}
    end

    test "broadcasts a single message to a single target", %{
      user: user,
      user_channel: user_channel,
      pid: pid,
      message: message,
      raw_message: raw_message
    } do
      test_cases = [
        {message, user, user.pid},
        {message, user_channel, user_channel.user_pid},
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
      user_channel: user_channel,
      pid: pid,
      message: message,
      raw_message: raw_message
    } do
      setup_expectations([
        {user.pid, raw_message},
        {user_channel.user_pid, raw_message},
        {pid, raw_message}
      ])

      assert :ok == Dispatcher.broadcast(message, :server, [user, user_channel, pid])

      Connection
      |> reject(:handle_send, 2)
    end

    test "broadcasts multiple messages to a single target", %{
      user: user,
      user_channel: user_channel,
      pid: pid,
      message: message,
      raw_message: raw_message
    } do
      test_cases = [
        {user, user.pid},
        {user_channel, user_channel.user_pid},
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
      user_channel: user_channel,
      pid: pid,
      message: message,
      raw_message: raw_message
    } do
      for _ <- 1..2 do
        setup_expectations([
          {user.pid, raw_message},
          {user_channel.user_pid, raw_message},
          {pid, raw_message}
        ])
      end

      assert :ok == Dispatcher.broadcast([message, message], :server, [user, user_channel, pid])

      Connection
      |> reject(:handle_send, 2)
    end

    test "filters message tags based on recipient capabilities with :server context", %{user: _user} do
      user_with_caps = insert(:user, capabilities: ["MESSAGE-TAGS"])

      message_with_tags =
        Message.build(%{command: "NOTICE", params: ["test"], trailing: "hello"})
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
