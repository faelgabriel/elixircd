defmodule ElixIRCd.Commands.ChathistoryTest do
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Command
  alias ElixIRCd.History
  alias ElixIRCd.Message
  alias ElixIRCd.Tables.ClientBatch

  test "replays channel history in a chathistory batch with stable msgids and timestamps" do
    Memento.transaction!(fn ->
      user =
        insert(:user,
          nick: "Alice",
          identified_as: "Alice",
          capabilities: ["batch", "draft/chathistory", "message-tags", "server-time"]
        )

      channel = insert(:channel, name: "#history")
      insert(:user_channel, user: user, channel: channel)

      first = history_message("Alice", "#history", "first", "msg-1", ~U[2026-09-19 12:00:00.000Z])
      second = history_message("Alice", "#history", "second", "msg-2", ~U[2026-09-19 12:00:01.000Z])
      assert :ok = History.record(first, user)
      assert :ok = History.record(second, user)

      request = %Message{command: "CHATHISTORY", params: ["LATEST", "#history", "*", "10"]}
      assert :ok = Command.dispatch(user, request)

      assert_sent_messages([
        {user.pid, ~r/^(?:@time=\S+ )?:irc\.test BATCH \+(\S+) chathistory #history\r\n$/},
        {user.pid,
         ~r/^@batch=\S+;msgid=msg-1;time=2026-09-19T12:00:00\.000Z :Alice!ident@host PRIVMSG #history :first\r\n$/},
        {user.pid,
         ~r/^@batch=\S+;msgid=msg-2;time=2026-09-19T12:00:01\.000Z :Alice!ident@host PRIVMSG #history :second\r\n$/},
        {user.pid, ~r/^(?:@time=\S+ )?:irc\.test BATCH -\S+\r\n$/}
      ])
    end)
  end

  test "enforces channel membership and excludes events without event-playback" do
    Memento.transaction!(fn ->
      user =
        insert(:user,
          nick: "Alice",
          identified_as: "Alice",
          capabilities: ["batch", "draft/chathistory", "message-tags", "server-time"]
        )

      channel = insert(:channel, name: "#history")

      event = %{
        history_message("Alice", "#history", "topic", "topic-1", ~U[2026-09-19 12:00:00.000Z])
        | command: "TOPIC"
      }

      assert :ok = History.record(event, user)

      invalid = %Message{command: "CHATHISTORY", params: ["LATEST", "#history", "*", "10"]}
      assert :ok = Command.dispatch(user, invalid)
      assert_sent_message_contains(user.pid, ~r/ FAIL CHATHISTORY INVALID_TARGET LATEST /)
      Agent.update(@agent_name, fn _ -> [] end)

      insert(:user_channel, user: user, channel: channel)
      assert :ok = Command.dispatch(user, invalid)

      assert_sent_messages([
        {user.pid, ~r/^(?:@time=\S+ )?:irc\.test BATCH \+\S+ chathistory #history\r\n$/},
        {user.pid, ~r/^(?:@time=\S+ )?:irc\.test BATCH -\S+\r\n$/}
      ])
    end)
  end

  test "supports exclusive msgid bounds and reverse BETWEEN limits" do
    Memento.transaction!(fn ->
      user = insert(:user, nick: "Alice", identified_as: "Alice")

      for index <- 1..5 do
        message =
          history_message(
            "Alice",
            "Alice",
            "#{index}",
            "msg-#{index}",
            DateTime.add(~U[2026-09-19 12:00:00Z], index, :second)
          )

        History.record(message, user)
      end

      {:ok, target} = History.target_for_request(user, "Alice")

      assert Enum.map(History.query(target.key, "AFTER", {:msgid, "msg-2"}, nil, 10), & &1.msgid) == [
               "msg-3",
               "msg-4",
               "msg-5"
             ]

      assert Enum.map(History.query(target.key, "BETWEEN", {:msgid, "msg-5"}, {:msgid, "msg-1"}, 2), & &1.msgid) == [
               "msg-3",
               "msg-4"
             ]
    end)
  end

  test "paginates visible messages before the limit and supports clients without batch" do
    Memento.transaction!(fn ->
      user = insert(:user, nick: "Alice", identified_as: "Alice", capabilities: ["draft/chathistory"])
      channel = insert(:channel, name: "#history")
      insert(:user_channel, user: user, channel: channel)
      base = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.add(-5, :second)

      event = %{history_message("Alice", "#history", "topic", "event", base) | command: "TOPIC"}
      History.record(event, user)
      History.record(history_message("Alice", "#history", "first", "one", DateTime.add(base, 1, :second)), user)
      History.record(history_message("Alice", "#history", "second", "two", DateTime.add(base, 2, :second)), user)

      assert :ok =
               Command.dispatch(user, %Message{
                 command: "CHATHISTORY",
                 params: ["AFTER", "#history", "msgid=event", "2"]
               })

      assert_sent_message_contains(user.pid, ~r/ PRIVMSG #history :first\r\n$/)
      assert_sent_message_contains(user.pid, ~r/ PRIVMSG #history :second\r\n$/)
      refute Enum.any?(Agent.get(@agent_name, & &1), fn {_pid, line} -> String.contains?(line, " BATCH ") end)
    end)
  end

  test "replays multiline as component messages for clients without multiline" do
    Memento.transaction!(fn ->
      user =
        insert(:user,
          nick: "Alice",
          identified_as: "Alice",
          capabilities: ["draft/chathistory", "batch", "message-tags", "server-time"]
        )

      channel = insert(:channel, name: "#history")
      insert(:user_channel, user: user, channel: channel)
      batch = ClientBatch.new(%{id: {user.pid, "r"}, user_pid: user.pid, reference: "r", target: "#history"})
      now = DateTime.utc_now() |> DateTime.truncate(:millisecond)

      lines = [
        history_message("Alice", "#history", "first", "line-1", now),
        history_message("Alice", "#history", "", "line-blank", now),
        history_message("Alice", "#history", "second", "line-2", now)
      ]

      History.record_multiline(user, batch, Enum.map(lines, &{&1, []}), "combined", DateTime.to_iso8601(now))
      assert :ok = Command.dispatch(user, %Message{command: "CHATHISTORY", params: ["LATEST", "#history", "*", "10"]})

      messages = Agent.get(@agent_name, & &1) |> Enum.map(&elem(&1, 1))
      assert Enum.count(messages, &String.contains?(&1, " BATCH ")) == 2
      assert Enum.any?(messages, &String.contains?(&1, "msgid=combined"))
      assert Enum.any?(messages, &String.contains?(&1, " PRIVMSG #history :first"))
      assert Enum.any?(messages, &String.contains?(&1, " PRIVMSG #history :second"))
      refute Enum.any?(messages, &String.contains?(&1, " PRIVMSG #history :\r\n"))
    end)
  end

  test "serves TARGETS and BETWEEN and validates registration, capabilities, references and limits" do
    Memento.transaction!(fn ->
      unregistered =
        insert(:user,
          nick: "Pending",
          registered: false,
          capabilities: ["batch", "draft/chathistory"]
        )

      assert :ok = Command.dispatch(unregistered, %Message{command: "CHATHISTORY", params: ["TARGETS", "*", "*", "10"]})
      assert_sent_message_contains(unregistered.pid, ~r/ FAIL CHATHISTORY INVALID_PARAMS \*/)

      unavailable = insert(:user, nick: "Unavailable")
      assert :ok = Command.dispatch(unavailable, %Message{command: "CHATHISTORY", params: ["TARGETS", "*", "*", "10"]})
      assert_sent_message_contains(unavailable.pid, ~r/ FAIL CHATHISTORY NEED_CAP TARGETS/)

      user =
        insert(:user,
          nick: "Alice",
          identified_as: "Alice",
          capabilities: ["batch", "draft/chathistory", "draft/event-playback"]
        )

      channel = insert(:channel, name: "#history")
      insert(:user_channel, user: user, channel: channel)
      History.record(history_message("Alice", "#history", "first", "one", ~U[2026-09-19 12:00:00Z]), user)
      History.record(history_message("Alice", "#history", "second", "two", ~U[2026-09-19 12:00:01Z]), user)

      assert :ok =
               Command.dispatch(user, %Message{
                 command: "CHATHISTORY",
                 params: ["TARGETS", "timestamp=2026-09-19T11:00:00Z", "timestamp=2026-09-19T13:00:00Z", "999"]
               })

      assert_sent_message_contains(user.pid, ~r/ CHATHISTORY TARGETS #history 2026-09-19T12:00:01(?:\.000)?Z/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok =
               Command.dispatch(user, %Message{
                 command: "CHATHISTORY",
                 params: ["BETWEEN", "#history", "msgid=one", "msgid=two", "10"]
               })

      assert_sent_message_contains(user.pid, ~r/ BATCH \+\S+ chathistory #history/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = Command.dispatch(user, %Message{command: "CHATHISTORY", params: ["TARGETS", "bad", "*", "10"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL CHATHISTORY INVALID_PARAMS TARGETS/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok =
               Command.dispatch(user, %Message{
                 command: "CHATHISTORY",
                 params: ["BETWEEN", "#history", "bad", "*", "10"]
               })

      assert_sent_message_contains(user.pid, ~r/ FAIL CHATHISTORY INVALID_PARAMS BETWEEN/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = Command.dispatch(user, %Message{command: "CHATHISTORY", params: ["LATEST", "#history", "*", "0"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL CHATHISTORY INVALID_PARAMS LATEST/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = Command.dispatch(user, %Message{command: "CHATHISTORY", params: ["UNKNOWN"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL CHATHISTORY INVALID_PARAMS UNKNOWN/)
      assert :ok = Command.dispatch(user, %Message{command: "CHATHISTORY", params: []})
      assert_sent_message_contains(user.pid, ~r/ FAIL CHATHISTORY INVALID_PARAMS \*/)
    end)
  end

  defp history_message(nick, target, text, msgid, timestamp) do
    %Message{
      command: "PRIVMSG",
      prefix: "#{nick}!ident@host",
      params: [target],
      trailing: text,
      tags: %{"msgid" => msgid, "time" => DateTime.to_iso8601(timestamp)}
    }
  end
end
