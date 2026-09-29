defmodule ElixIRCd.Commands.BatchTest do
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Command
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChatHistory
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.ServerLink.Directory
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.UserPayload

  test "rejects remote multiline without sending any partial line over S2S" do
    uid = UserPayload.new_uid()
    remote = build(:user, nick: "Remote") |> UserPayload.from_local(uid)
    table = Directory.create()

    replica = %{
      Replica.new()
      | users: %{{"east.example", uid} => remote},
        nick_keys: %{"remote" => {"east.example", uid}}
    }

    Directory.sync(table, Replica.new(), replica)
    test_pid = self()
    Mimic.stub(Hub, :send_direct, fn _outbound -> send(test_pid, :unexpected_remote_line) end)

    Memento.transaction!(fn ->
      sender = insert(:user, nick: "Alice", capabilities: ["message-tags", "batch", "draft/multiline"])

      for command <- ["PRIVMSG", "NOTICE"] do
        start = %Message{command: "BATCH", params: ["+remote", "draft/multiline", "Remote"]}
        line = %Message{command: command, params: ["Remote"], trailing: "hello", tags: %{"batch" => "remote"}}
        finish = %Message{command: "BATCH", params: ["-remote"]}

        assert :ok = Command.dispatch(sender, start)
        assert :ok = Command.dispatch(sender, line)
        assert :ok = Command.dispatch(sender, finish)
      end

      assert_sent_messages_count_containing(sender.pid, ~r/ FAIL BATCH MULTILINE_INVALID /, 2)
    end)

    refute_received :unexpected_remote_line
  end

  test "delivers multiline as a shared batch and a coherent legacy fallback" do
    Memento.transaction!(fn ->
      channel = insert(:channel, name: "#test")

      sender =
        insert(:user,
          nick: "Alice",
          capabilities: ["message-tags", "batch", "echo-message", "server-time", "labeled-response", "draft/multiline"]
        )

      capable = insert(:user, nick: "Bob", capabilities: ["message-tags", "batch", "server-time", "draft/multiline"])
      fallback = insert(:user, nick: "Charlie", capabilities: ["message-tags", "server-time"])

      for user <- [sender, capable, fallback], do: insert(:user_channel, user: user, channel: channel)

      assert :ok =
               Command.dispatch(sender, %Message{
                 command: "BATCH",
                 params: ["+client", "draft/multiline", "#test"],
                 tags: %{"label" => "xyz"}
               })

      assert :ok = Command.dispatch(sender, line("client", "hello", %{}))
      assert :ok = Command.dispatch(sender, line("client", "world", %{"draft/multiline-concat" => nil}))
      assert :ok = Command.dispatch(sender, %Message{command: "BATCH", params: ["-client"]})

      assert_sent_messages([
        {sender.pid,
         ~r/^@label=xyz;msgid=\S+;time=\S+ :Alice!~username@hostname BATCH \+\S+ draft\/multiline #test\r\n$/},
        {sender.pid, ~r/^@batch=\S+;time=\S+ :Alice!~username@hostname PRIVMSG #test :hello\r\n$/},
        {sender.pid,
         ~r/^@batch=\S+;draft\/multiline-concat;time=\S+ :Alice!~username@hostname PRIVMSG #test :world\r\n$/},
        {sender.pid, ~r/^@time=\S+ :Alice!~username@hostname BATCH -\S+\r\n$/},
        {capable.pid, ~r/^@msgid=\S+;time=\S+ :Alice!~username@hostname BATCH \+\S+ draft\/multiline #test\r\n$/},
        {capable.pid, ~r/^@batch=\S+;time=\S+ :Alice!~username@hostname PRIVMSG #test :hello\r\n$/},
        {capable.pid,
         ~r/^@batch=\S+;draft\/multiline-concat;time=\S+ :Alice!~username@hostname PRIVMSG #test :world\r\n$/},
        {capable.pid, ~r/^@time=\S+ :Alice!~username@hostname BATCH -\S+\r\n$/},
        {fallback.pid, ~r/^@msgid=\S+;time=\S+ :Alice!~username@hostname PRIVMSG #test :hello\r\n$/},
        {fallback.pid, ~r/^@time=\S+ :Alice!~username@hostname PRIVMSG #test :world\r\n$/}
      ])
    end)
  end

  test "rejects invalid references, blank concatenation, and configured limits" do
    original = Application.fetch_env!(:elixircd, :multiline)
    on_exit(fn -> Application.put_env(:elixircd, :multiline, original) end)
    Application.put_env(:elixircd, :multiline, enabled: true, max_bytes: 8, max_lines: 2)

    Memento.transaction!(fn ->
      user = insert(:user, nick: "Alice", capabilities: ["batch", "draft/multiline"])
      assert :ok = Command.dispatch(user, %Message{command: "BATCH", params: ["+one", "draft/multiline", "#test"]})
      assert :ok = Command.dispatch(user, line("wrong", "hello", %{}))
      assert_sent_message_contains(user.pid, ~r/ FAIL BATCH MULTILINE_INVALID /)
      assert :ok = Command.dispatch(user, %Message{command: "BATCH", params: ["-one"]})

      assert :ok = Command.dispatch(user, %Message{command: "BATCH", params: ["+two", "draft/multiline", "#test"]})
      assert :ok = Command.dispatch(user, line("two", "", %{"draft/multiline-concat" => nil}))
      assert_sent_message_contains(user.pid, ~r/ FAIL BATCH MULTILINE_INVALID /)
    end)
  end

  test "persists and replays multiline as one nested history batch" do
    Memento.transaction!(fn ->
      channel = insert(:channel, name: "#test")

      user =
        insert(:user,
          nick: "Alice",
          identified_as: "Alice",
          capabilities: [
            "message-tags",
            "server-time",
            "batch",
            "draft/multiline",
            "draft/chathistory"
          ]
        )

      insert(:user_channel, user: user, channel: channel, modes: [:o])

      assert :ok = Command.dispatch(user, %Message{command: "BATCH", params: ["+client", "draft/multiline", "#test"]})
      assert :ok = Command.dispatch(user, line("client", "first", %{}))
      assert :ok = Command.dispatch(user, line("client", "second", %{"draft/multiline-concat" => nil}))
      assert :ok = Command.dispatch(user, %Message{command: "BATCH", params: ["-client"]})
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok =
               Command.dispatch(user, %Message{command: "CHATHISTORY", params: ["LATEST", "#test", "*", "10"]})

      assert_sent_messages([
        {user.pid, ~r/^@time=\S+ :irc\.test BATCH \+\S+ chathistory #test\r\n$/},
        {user.pid, ~r/^@batch=\S+;msgid=\S+;time=\S+ :irc\.test BATCH \+\S+ draft\/multiline #test\r\n$/},
        {user.pid, ~r/^@batch=\S+;time=\S+ :Alice!~username@hostname PRIVMSG #test :first\r\n$/},
        {user.pid,
         ~r/^@batch=\S+;draft\/multiline-concat;time=\S+ :Alice!~username@hostname PRIVMSG #test :second\r\n$/},
        {user.pid, ~r/^@batch=\S+;time=\S+ :irc\.test BATCH -\S+\r\n$/},
        {user.pid, ~r/^@time=\S+ :irc\.test BATCH -\S+\r\n$/}
      ])
    end)
  end

  test "discards the whole multiline delivery and history when a later line is rejected" do
    Memento.transaction!(fn ->
      channel = insert(:channel, name: "#test", modes: [:c])

      sender =
        insert(:user,
          nick: "Alice",
          capabilities: ["message-tags", "batch", "echo-message", "draft/multiline"]
        )

      recipient = insert(:user, nick: "Bob", capabilities: ["message-tags", "batch", "draft/multiline"])
      for user <- [sender, recipient], do: insert(:user_channel, user: user, channel: channel)

      assert :ok = Command.dispatch(sender, %Message{command: "BATCH", params: ["+atomic", "draft/multiline", "#test"]})
      assert :ok = Command.dispatch(sender, line("atomic", "accepted first", %{}))
      assert :ok = Command.dispatch(sender, line("atomic", "\x0304rejected later", %{}))
      assert :ok = Command.dispatch(sender, %Message{command: "BATCH", params: ["-atomic"]})

      assert_sent_message_contains(sender.pid, ~r/ 404 Alice #test :Cannot send to channel \(\+c - no colors allowed\)/)
      assert_sent_messages_amount(sender.pid, 2)
      assert_sent_messages_amount(recipient.pid, 0)
      assert ChatHistory.all() == []
    end)
  end

  test "rejects unavailable, duplicate and unknown batches" do
    Memento.transaction!(fn ->
      unavailable = insert(:user, nick: "Unavailable")

      assert :ok =
               Command.dispatch(unavailable, %Message{command: "BATCH", params: ["+one", "draft/multiline", "#test"]})

      assert_sent_message_contains(unavailable.pid, ~r/ FAIL BATCH MULTILINE_INVALID/)

      user = insert(:user, nick: "Alice", capabilities: ["batch", "draft/multiline"])
      assert :ok = Command.dispatch(user, %Message{command: "BATCH", params: []})
      assert :ok = Command.dispatch(user, line("absent", "ignored", %{}))
      assert :ok = Command.dispatch(user, %Message{command: "BATCH", params: ["-missing"]})
      assert_sent_message_contains(user.pid, ~r/Unknown multiline batch/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = Command.dispatch(user, %Message{command: "BATCH", params: ["+one", "draft/multiline", "#test"]})
      assert :ok = Command.dispatch(user, %Message{command: "BATCH", params: ["+two", "draft/multiline", "#test"]})
      assert_sent_message_contains(user.pid, ~r/A multiline batch is already active or invalid/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = Command.dispatch(user, line("unknown", "ignored", %{}))
      assert_sent_message_contains(user.pid, ~r/Unexpected batch reference/)
      assert :ok = Command.dispatch(user, line("one", "ignored after invalidation", %{}))
    end)
  end

  test "enforces target, command, line and byte invariants" do
    original = Application.fetch_env!(:elixircd, :multiline)
    on_exit(fn -> Application.put_env(:elixircd, :multiline, original) end)

    Memento.transaction!(fn ->
      user = insert(:user, nick: "Alice", capabilities: ["batch", "draft/multiline"])

      start_batch(user, "target")

      assert :ok =
               Command.dispatch(user, %Message{
                 command: "PRIVMSG",
                 params: ["#other"],
                 trailing: "wrong target",
                 tags: %{"batch" => "target"}
               })

      assert_sent_message_contains(user.pid, ~r/ FAIL BATCH MULTILINE_INVALID_TARGET #test #other/)
      finish_batch(user, "target")

      Application.put_env(:elixircd, :multiline, enabled: true, max_bytes: 100, max_lines: 1)
      start_batch(user, "lines")
      assert :ok = Command.dispatch(user, line("lines", "one", %{}))
      assert :ok = Command.dispatch(user, line("lines", "two", %{}))
      assert_sent_message_contains(user.pid, ~r/ FAIL BATCH MULTILINE_MAX_LINES 1/)
      finish_batch(user, "lines")

      Application.put_env(:elixircd, :multiline, enabled: true, max_bytes: 3, max_lines: 10)
      start_batch(user, "bytes")
      assert :ok = Command.dispatch(user, line("bytes", "four", %{}))
      assert_sent_message_contains(user.pid, ~r/ FAIL BATCH MULTILINE_MAX_BYTES 3/)
      finish_batch(user, "bytes")

      Application.put_env(:elixircd, :multiline, enabled: true, max_bytes: 100, max_lines: 10)
      start_batch(user, "command")
      assert :ok = Command.dispatch(user, line("command", "one", %{}))

      assert :ok =
               Command.dispatch(user, %Message{
                 command: "NOTICE",
                 params: ["#test"],
                 trailing: "two",
                 tags: %{"batch" => "command"}
               })

      assert_sent_message_contains(user.pid, ~r/All lines must use the same command/)
      finish_batch(user, "command")
    end)
  end

  test "counts line separators, rejects all-blank messages, and does not execute services during validation" do
    original = Application.fetch_env!(:elixircd, :multiline)
    on_exit(fn -> Application.put_env(:elixircd, :multiline, original) end)
    Application.put_env(:elixircd, :multiline, enabled: true, max_bytes: 3, max_lines: 10)

    Memento.transaction!(fn ->
      user = insert(:user, nick: "Alice", capabilities: ["batch", "draft/multiline"])
      start_batch(user, "bytes")
      Command.dispatch(user, line("bytes", "a", %{}))
      Command.dispatch(user, line("bytes", "bc", %{}))
      assert_sent_message_contains(user.pid, ~r/ FAIL BATCH MULTILINE_MAX_BYTES 3/)
      finish_batch(user, "bytes")
      Agent.update(@agent_name, fn _ -> [] end)

      start_batch(user, "blank")
      Command.dispatch(user, line("blank", "", %{}))
      finish_batch(user, "blank")
      assert_sent_message_contains(user.pid, ~r/ FAIL BATCH MULTILINE_INVALID :Multiline message cannot be blank/)
      Agent.update(@agent_name, fn _ -> [] end)

      Application.put_env(:elixircd, :multiline, enabled: true, max_bytes: 100, max_lines: 10)
      start_batch(user, "empty")
      finish_batch(user, "empty")
      assert_sent_message_contains(user.pid, ~r/ FAIL BATCH MULTILINE_INVALID :Multiline batch is empty/)
      Agent.update(@agent_name, fn _ -> [] end)

      start_batch(user, "tags")
      Command.dispatch(user, line("tags", "hello", %{"unexpected" => "value"}))
      assert_sent_message_contains(user.pid, ~r/Unexpected tags on multiline line/)
      finish_batch(user, "tags")
      Agent.update(@agent_name, fn _ -> [] end)

      start_batch(user, "command")
      Command.dispatch(user, %Message{command: "PING", params: ["#test"], tags: %{"batch" => "command"}})
      assert_sent_message_contains(user.pid, ~r/All lines must use one target and message command/)
      finish_batch(user, "command")
      Agent.update(@agent_name, fn _ -> [] end)

      Command.dispatch(user, %Message{command: "BATCH", params: ["+service", "draft/multiline", "NickServ"]})

      Command.dispatch(user, %Message{
        command: "PRIVMSG",
        params: ["NickServ"],
        trailing: "REGISTER long-password",
        tags: %{"batch" => "service"}
      })

      finish_batch(user, "service")

      assert_sent_message_contains(
        user.pid,
        ~r/ FAIL BATCH MULTILINE_INVALID :Multiline message could not be delivered/
      )

      assert {:error, :registered_nick_not_found} = RegisteredNicks.get_by_nickname("Alice")
    end)
  end

  defp line(reference, text, tags) do
    %Message{
      command: "PRIVMSG",
      params: ["#test"],
      trailing: text,
      tags: Map.put(tags, "batch", reference)
    }
  end

  defp start_batch(user, reference) do
    Command.dispatch(user, %Message{command: "BATCH", params: ["+" <> reference, "draft/multiline", "#test"]})
  end

  defp finish_batch(user, reference) do
    Command.dispatch(user, %Message{command: "BATCH", params: ["-" <> reference]})
  end
end
