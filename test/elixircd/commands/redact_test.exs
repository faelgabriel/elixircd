defmodule ElixIRCd.Commands.RedactTest do
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Command
  alias ElixIRCd.History
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChatHistory
  alias ElixIRCd.Tables.ClientBatch

  test "the author and channel operator can redact, while another member cannot" do
    Memento.transaction!(fn ->
      channel = insert(:channel, name: "#redact")
      alice = insert(:user, nick: "Alice", capabilities: ["draft/message-redaction", "message-tags"])
      bob = insert(:user, nick: "Bob", capabilities: ["draft/message-redaction", "message-tags"])
      insert(:user_channel, user: alice, channel: channel, modes: [:o])
      insert(:user_channel, user: bob, channel: channel)

      message = history_message("Bob", "#redact", "msg-1")
      History.record(message, bob)

      assert :ok =
               Command.dispatch(bob, %Message{
                 command: "REDACT",
                 params: ["#redact", "msg-1"]
               })

      assert_sent_messages([
        {alice.pid, ":Bob!~username@hostname REDACT #redact msg-1\r\n"},
        {bob.pid, ":Bob!~username@hostname REDACT #redact msg-1\r\n"}
      ])

      assert {:ok, redacted} = ChatHistory.get_by_msgid("msg-1")
      assert redacted.redacted_at
      assert History.query(redacted.target_key, "LATEST", :all, nil, 10) == []

      second = history_message("Alice", "#redact", "msg-2")
      History.record(second, alice)
      assert :ok = Command.dispatch(bob, %Message{command: "REDACT", params: ["#redact", "msg-2"]})
      assert_sent_message_contains(bob.pid, ~r/ FAIL REDACT REDACT_FORBIDDEN #redact msg-2 /)
      refute ChatHistory.get_by_msgid("msg-2") |> elem(1) |> Map.get(:redacted_at)
    end)
  end

  test "does not relay REDACT to clients that did not negotiate it" do
    Memento.transaction!(fn ->
      channel = insert(:channel, name: "#redact")
      alice = insert(:user, nick: "Alice", capabilities: ["draft/message-redaction", "message-tags"])
      legacy = insert(:user, nick: "Legacy", capabilities: ["message-tags"])
      insert(:user_channel, user: alice, channel: channel, modes: [:o])
      insert(:user_channel, user: legacy, channel: channel)
      History.record(history_message("Alice", "#redact", "msg-3"), alice)

      assert :ok = Command.dispatch(alice, %Message{command: "REDACT", params: ["#redact", "msg-3"]})
      assert_sent_messages([{alice.pid, ":Alice!~username@hostname REDACT #redact msg-3\r\n"}])
      assert_sent_messages_amount(legacy.pid, 0)
    end)
  end

  test "an IRC operator can redact a channel message without joining it" do
    Memento.transaction!(fn ->
      channel = insert(:channel, name: "#redact")
      author = insert(:user, nick: "Author", capabilities: ["draft/message-redaction"])
      operator = insert(:user, nick: "Oper", modes: [:o], capabilities: ["draft/message-redaction"])
      insert(:user_channel, user: author, channel: channel)
      History.record(history_message("Author", "#redact", "oper-redaction"), author)

      assert :ok = Command.dispatch(operator, %Message{command: "REDACT", params: ["#redact", "oper-redaction"]})
      assert {:ok, redacted} = ChatHistory.get_by_msgid("oper-redaction")
      assert redacted.redacted_at
      assert_sent_message_contains(author.pid, ~r/ REDACT #redact oper-redaction/)
    end)
  end

  test "does not redact stored channel events" do
    Memento.transaction!(fn ->
      channel = insert(:channel, name: "#redact")
      operator = insert(:user, nick: "Oper", modes: [:o], capabilities: ["draft/message-redaction"])
      insert(:user_channel, user: operator, channel: channel, modes: [:o])

      History.record_channel_event(
        %Message{command: "TOPIC", params: ["#redact"], trailing: "topic"},
        operator,
        "#redact"
      )

      event = ChatHistory.for_target("channel:#redact") |> Enum.find(&(&1.message.command == "TOPIC"))
      assert :ok = Command.dispatch(operator, %Message{command: "REDACT", params: ["#redact", event.msgid]})
      assert_sent_message_contains(operator.pid, ~r/ FAIL REDACT UNKNOWN_MSGID #redact /)
      assert {:ok, unchanged} = ChatHistory.get_by_msgid(event.msgid)
      refute unchanged.redacted_at
    end)
  end

  test "redacts valid multiline history and rejects malformed stored entries" do
    Memento.transaction!(fn ->
      channel = insert(:channel, name: "#redact")
      user = insert(:user, nick: "Alice", capabilities: ["draft/message-redaction"])
      insert(:user_channel, user: user, channel: channel, modes: [:o])
      timestamp = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
      batch = ClientBatch.new(%{id: {user.pid, "r"}, user_pid: user.pid, reference: "r", target: "#redact"})
      line = history_message("Alice", "#redact", "line")

      History.record_multiline(user, batch, [{line, []}], "multiline", timestamp)
      assert :ok = Command.dispatch(user, %Message{command: "REDACT", params: ["#redact", "multiline"]})
      assert {:ok, redacted} = ChatHistory.get_by_msgid("multiline")
      assert redacted.redacted_at
      Agent.update(@agent_name, fn _ -> [] end)

      for {msgid, message} <- [
            {"invalid-multiline", %{kind: :multiline, lines: [%Message{command: "TOPIC", params: ["#redact"]}]}},
            {"invalid-kind", %{kind: :other}}
          ] do
        ChatHistory.create(%{
          id: {"channel:#redact", DateTime.utc_now() |> DateTime.to_unix(:microsecond), msgid},
          target_type: :channel,
          target_key: "channel:#redact",
          target_name: "#redact",
          msgid: msgid,
          message: message,
          sender_account_key: History.identity_key(user),
          occurred_at: DateTime.utc_now()
        })

        assert :ok = Command.dispatch(user, %Message{command: "REDACT", params: ["#redact", msgid]})
        assert_sent_message_contains(user.pid, ~r/ FAIL REDACT UNKNOWN_MSGID #redact /)
        assert {:ok, unchanged} = ChatHistory.get_by_msgid(msgid)
        refute unchanged.redacted_at
        Agent.update(@agent_name, fn _ -> [] end)
      end
    end)
  end

  test "validates registration, capability, target, msgid and reason" do
    original = Application.fetch_env!(:elixircd, :redaction)
    on_exit(fn -> Application.put_env(:elixircd, :redaction, original) end)
    Application.put_env(:elixircd, :redaction, Keyword.put(original, :max_reason_length, 3))

    Memento.transaction!(fn ->
      unregistered = insert(:user, nick: "Pending", registered: false, capabilities: ["draft/message-redaction"])
      assert :ok = Command.dispatch(unregistered, %Message{command: "REDACT", params: ["#test", "id"]})
      assert_sent_message_contains(unregistered.pid, ~r/ FAIL REDACT INVALID_TARGET \*/)

      unavailable = insert(:user, nick: "Unavailable")
      assert :ok = Command.dispatch(unavailable, %Message{command: "REDACT", params: ["#test", "id"]})
      assert_sent_message_contains(unavailable.pid, ~r/ FAIL REDACT NEED_CAP #test id/)

      user = insert(:user, nick: "Alice", identified_as: "Alice", capabilities: ["draft/message-redaction"])
      channel = insert(:channel, name: "#test")
      insert(:user_channel, user: user, channel: channel, modes: [:o])
      History.record(history_message("Alice", "#test", "known"), user)

      assert :ok = Command.dispatch(user, %Message{command: "REDACT", params: []})
      assert_sent_message_contains(user.pid, ~r/ FAIL REDACT INVALID_PARAMS \*/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = Command.dispatch(user, %Message{command: "REDACT", params: ["Missing", "known"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL REDACT INVALID_TARGET Missing/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = Command.dispatch(user, %Message{command: "REDACT", params: ["#test", "missing"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL REDACT UNKNOWN_MSGID #test missing/)
      Agent.update(@agent_name, fn _ -> [] end)

      other_channel = insert(:channel, name: "#other")
      insert(:user_channel, user: user, channel: other_channel, modes: [:o])
      assert :ok = Command.dispatch(user, %Message{command: "REDACT", params: ["#other", "known"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL REDACT UNKNOWN_MSGID #other known/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = Command.dispatch(user, %Message{command: "REDACT", params: ["#test", "known"], trailing: "long"})
      assert_sent_message_contains(user.pid, ~r/ FAIL REDACT INVALID_PARAMS #test known/)
    end)
  end

  test "redacts direct history for authors and operators, with online and offline peers" do
    Memento.transaction!(fn ->
      alice = insert(:user, nick: "Alice", identified_as: "Alice", capabilities: ["draft/message-redaction"])
      bob = insert(:user, nick: "Bob", identified_as: "Bob", capabilities: ["draft/message-redaction"])

      History.record(history_message("Alice", "Bob", "direct-online"), alice)

      assert :ok =
               Command.dispatch(alice, %Message{
                 command: "REDACT",
                 params: ["Bob", "direct-online"],
                 trailing: "obsolete"
               })

      assert_sent_message_contains(alice.pid, ~r/ REDACT Bob direct-online/)
      assert_sent_message_contains(bob.pid, ~r/ REDACT Bob direct-online/)
      Agent.update(@agent_name, fn _ -> [] end)

      insert(:registered_nick, nickname: "Offline", account_name: "Offline")
      History.record(history_message("Alice", "Offline", "direct-offline"), alice)
      assert :ok = Command.dispatch(alice, %Message{command: "REDACT", params: ["Offline", "direct-offline"]})
      assert_sent_message_contains(alice.pid, ~r/ REDACT Offline direct-offline/)
    end)
  end

  defp history_message(nick, target, msgid) do
    %Message{
      command: "PRIVMSG",
      prefix: "#{nick}!~username@hostname",
      params: [target],
      trailing: "message",
      tags: %{
        "msgid" => msgid,
        "time" => DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
      }
    }
  end
end
