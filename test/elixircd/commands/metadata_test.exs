defmodule ElixIRCd.Commands.MetadataTest do
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Command
  alias ElixIRCd.Message
  alias ElixIRCd.Metadata

  test "sets, gets, lists and clears account metadata in protocol batches" do
    Memento.transaction!(fn ->
      user = insert(:user, nick: "Alice", identified_as: "Alice", capabilities: ["batch", "draft/metadata-3"])

      assert :ok = dispatch(user, ["*", "SET", "display-name"], "Alice Cooper")
      assert_sent_message_contains(user.pid, ~r/ 761 Alice Alice display-name \* :Alice Cooper\r\n$/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["*", "GET", "display-name"])
      assert_sent_message_contains(user.pid, ~r/ BATCH \+\S+ metadata Alice\r\n$/)
      assert_sent_message_contains(user.pid, ~r/ 761 Alice Alice display-name \* :Alice Cooper\r\n$/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["*", "CLEAR"])
      assert_sent_message_contains(user.pid, ~r/ 766 Alice Alice display-name :key not set\r\n$/)
    end)
  end

  test "notifies subscribed shared-channel users and protects private channels" do
    Memento.transaction!(fn ->
      alice = insert(:user, nick: "Alice", capabilities: ["batch", "draft/metadata-3"])
      bob = insert(:user, nick: "Bob", capabilities: ["batch", "draft/metadata-3"])
      channel = insert(:channel, name: "#secret", modes: [:i])
      insert(:user_channel, user: alice, channel: channel, modes: [:o])

      assert :ok = dispatch(bob, ["*", "SUB", "display-name"])
      assert_sent_message_contains(bob.pid, ~r/ 770 Bob display-name\r\n$/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(alice, ["*", "SET", "display-name"], "A")
      assert_sent_messages_amount(bob.pid, 0)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(bob, ["#secret", "GET", "display-name"])
      assert_sent_message_contains(bob.pid, ~r/ FAIL METADATA KEY_NO_PERMISSION #secret \* /)

      insert(:user_channel, user: bob, channel: channel)
      Agent.update(@agent_name, fn _ -> [] end)
      assert :ok = dispatch(alice, ["*", "SET", "display-name"], "AA")
      assert_sent_message_contains(bob.pid, ~r/ 761 Bob Alice display-name \* :AA\r\n$/)
    end)
  end

  test "uses current METADATA notifications and keeps authenticated records durable" do
    Memento.transaction!(fn ->
      alice = insert(:user, nick: "Alice", identified_as: "Alice", capabilities: ["batch", "draft/metadata-2"])
      bob = insert(:user, nick: "Bob", capabilities: ["batch", "draft/metadata-2"])
      channel = insert(:channel, name: "#test")
      insert(:user_channel, user: alice, channel: channel, modes: [:o])
      insert(:user_channel, user: bob, channel: channel)

      assert :ok = dispatch(bob, ["*", "SUB", "avatar"])
      Agent.update(@agent_name, fn _ -> [] end)
      assert :ok = dispatch(alice, ["*", "SET", "avatar"], "https://example.test/a.png")
      assert_sent_message_contains(bob.pid, ~r/ METADATA Alice avatar \* :https:\/\/example.test\/a.png\r\n$/)

      {:ok, target} = Metadata.resolve_target(alice, "*")
      assert Metadata.get(target, "avatar").value == "https://example.test/a.png"
    end)
  end

  test "SYNC includes channel member metadata and MONITOR subscribers receive updates" do
    Memento.transaction!(fn ->
      alice = insert(:user, nick: "Alice", identified_as: "Alice", capabilities: ["batch", "draft/metadata-2"])
      bob = insert(:user, nick: "Bob", capabilities: ["batch", "draft/metadata-2"])
      watcher = insert(:user, nick: "Watcher", capabilities: ["batch", "draft/metadata-2"])
      channel = insert(:channel, name: "#test")
      insert(:user_channel, user: alice, channel: channel)
      insert(:user_channel, user: bob, channel: channel)
      insert(:user_monitor, user: watcher, target_nick: "Alice")

      dispatch(bob, ["*", "SUB", "avatar"])
      dispatch(watcher, ["*", "SUB", "avatar"])
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(alice, ["*", "SET", "avatar"], "photo")
      assert_sent_message_contains(watcher.pid, ~r/ METADATA Alice avatar \* :photo\r\n$/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(bob, ["#test", "SYNC"])
      assert_sent_message_contains(bob.pid, ~r/ METADATA Alice avatar \* :photo\r\n$/)
    end)
  end

  test "serves the withdrawn numeric protocol only when explicitly enabled" do
    original = Application.fetch_env!(:elixircd, :compatibility)
    on_exit(fn -> Application.put_env(:elixircd, :compatibility, original) end)
    Application.put_env(:elixircd, :compatibility, Keyword.put(original, :deprecated_metadata, true))

    Memento.transaction!(fn ->
      user = insert(:user, nick: "Alice", capabilities: [])

      assert :ok = dispatch(user, ["*", "GET", "display-name"])
      assert_sent_messages([{user.pid, ":irc.test 766 Alice display-name :No matching metadata key\r\n"}])
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["*", "SET", "display-name"], "Alice Cooper")

      assert_sent_messages([
        {user.pid, ":irc.test 761 Alice display-name * :Alice Cooper\r\n"},
        {user.pid, ":irc.test 762 Alice * :End of metadata\r\n"}
      ])
    end)
  end

  test "reports current protocol validation, authorization and limit errors" do
    original = Application.fetch_env!(:elixircd, :metadata)
    on_exit(fn -> Application.put_env(:elixircd, :metadata, original) end)
    Application.put_env(:elixircd, :metadata, Keyword.merge(original, max_keys: 1, max_subscriptions: 1))

    Memento.transaction!(fn ->
      user = insert(:user, nick: "Alice", capabilities: ["batch", "draft/metadata-3"])
      other = insert(:user, nick: "Bob", capabilities: ["batch", "draft/metadata-3"])

      assert :ok = dispatch(user, ["Missing", "GET", "one"])
      assert_sent_message_contains(user.pid, ~r/ FAIL METADATA INVALID_TARGET Missing/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["*", "GET", "INVALID", "missing"])
      assert_sent_message_contains(user.pid, ~r/ FAIL METADATA KEY_INVALID INVALID/)
      assert_sent_message_contains(user.pid, ~r/ 766 Alice Alice/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["*", "SET", "INVALID"], "value")
      assert_sent_message_contains(user.pid, ~r/ FAIL METADATA KEY_INVALID INVALID/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["*", "SET", "bad-value"], "line\nbreak")
      assert_sent_message_contains(user.pid, ~r/ FAIL METADATA VALUE_INVALID :Invalid metadata value/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["*", "SET", "one"], "1")
      Agent.update(@agent_name, fn _ -> [] end)
      assert :ok = dispatch(user, ["*", "SET", "two"], "2")
      assert_sent_message_contains(user.pid, ~r/ FAIL METADATA LIMIT_REACHED \*/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["*", "SET", "missing"])
      assert_sent_message_contains(user.pid, ~r/ FAIL METADATA KEY_NOT_SET \* missing/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["Bob", "SET", "one"], "2")
      assert_sent_message_contains(user.pid, ~r/ FAIL METADATA KEY_NO_PERMISSION Bob one/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["Bob", "CLEAR"])
      assert_sent_message_contains(user.pid, ~r/ FAIL METADATA KEY_NO_PERMISSION Bob \*/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["Missing", "LIST"])
      assert_sent_message_contains(user.pid, ~r/ FAIL METADATA INVALID_TARGET Missing/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["*", "LIST"])
      assert_sent_message_contains(user.pid, ~r/ 761 Alice Alice one \* :1/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["Missing", "SET", "one"], "1")
      assert_sent_message_contains(user.pid, ~r/ FAIL METADATA INVALID_TARGET Missing/)
      assert :ok = dispatch(user, ["Missing", "CLEAR"])
      assert_sent_message_contains(user.pid, ~r/ FAIL METADATA INVALID_TARGET Missing/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["*", "SET", "one"])
      assert_sent_message_contains(user.pid, ~r/ 766 Alice Alice one/)

      assert :ok = dispatch(user, ["*", "SUB", "INVALID", "one", "one", "two"])
      assert_sent_message_contains(user.pid, ~r/ FAIL METADATA KEY_INVALID INVALID/)
      assert_sent_message_contains(user.pid, ~r/ FAIL METADATA TOO_MANY_SUBS two/)
      assert_sent_message_contains(user.pid, ~r/ 770 Alice one/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["*", "SUBS"])
      assert_sent_message_contains(user.pid, ~r/ 772 Alice one/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["*", "UNSUB", "INVALID", "one"])
      assert_sent_message_contains(user.pid, ~r/ FAIL METADATA KEY_INVALID INVALID/)
      assert_sent_message_contains(user.pid, ~r/ 771 Alice one/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["*", "SUBS"])
      assert_sent_message_contains(user.pid, ~r/ BATCH \+\S+ metadata-subs/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["*", "SYNC"])
      assert :ok = dispatch(user, ["Missing", "SYNC"])
      assert_sent_message_contains(user.pid, ~r/ FAIL METADATA INVALID_TARGET Missing/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["*", "UNKNOWN"])
      assert_sent_message_contains(user.pid, ~r/ FAIL METADATA SUBCOMMAND_INVALID UNKNOWN/)
      assert :ok = dispatch(user, [])
      assert_sent_message_contains(user.pid, ~r/ FAIL METADATA INVALID_PARAMS \*/)

      assert other.nick == "Bob"
    end)
  end

  test "gates metadata and covers legacy list and error replies" do
    original = Application.fetch_env!(:elixircd, :compatibility)
    on_exit(fn -> Application.put_env(:elixircd, :compatibility, original) end)

    Memento.transaction!(fn ->
      unavailable = insert(:user, nick: nil, registered: false, capabilities: [])
      assert :ok = dispatch(unavailable, ["*", "LIST"])
      assert_sent_message_contains(unavailable.pid, ~r/ FAIL METADATA NEED_CAP \*/)
    end)

    Application.put_env(:elixircd, :compatibility, Keyword.put(original, :deprecated_metadata, true))

    Memento.transaction!(fn ->
      user = insert(:user, nick: "Alice", capabilities: [])
      assert :ok = dispatch(user, ["*", "SET", "one"], "1")
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["*", "LIST"])
      assert_sent_message_contains(user.pid, ~r/ 761 Alice one \* :1/)
      assert_sent_message_contains(user.pid, ~r/ 762 Alice \* :End of metadata/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["*", "GET", "INVALID"])
      assert_sent_message_contains(user.pid, ~r/ 767 Alice INVALID :Invalid metadata key/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["Missing", "GET", "one"])
      assert_sent_message_contains(user.pid, ~r/ 765 Alice Missing :Invalid metadata target/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = dispatch(user, ["Missing", "LIST"])
      assert_sent_message_contains(user.pid, ~r/ 765 Alice Missing/)
      assert :ok = dispatch(user, ["Missing", "SET", "one"], "1")
      assert_sent_message_contains(user.pid, ~r/ 765 Alice Missing/)

      assert :ok = dispatch(user, ["*", "SET", "INVALID"], "1")
      assert_sent_message_contains(user.pid, ~r/ 769 Alice INVALID/)
      assert :ok = dispatch(user, [])
      assert_sent_message_contains(user.pid, ~r/ 765 Alice \*/)
      assert :ok = dispatch(user, ["*", "UNKNOWN"])
      assert_sent_message_contains(user.pid, ~r/ 765 Alice \*/)
    end)
  end

  test "uses an asterisk reply target before nickname selection" do
    original = Application.fetch_env!(:elixircd, :metadata)
    on_exit(fn -> Application.put_env(:elixircd, :metadata, original) end)
    Application.put_env(:elixircd, :metadata, Keyword.put(original, :before_connect, true))

    Memento.transaction!(fn ->
      user = insert(:user, nick: nil, registered: false, capabilities: ["batch", "draft/metadata-3"])
      assert :ok = dispatch(user, ["*", "GET", "missing"])
      assert_sent_message_contains(user.pid, ~r/ 766 \* \* missing/)
      assert :ok = dispatch(user, ["*", "SUB", "key"])
      assert_sent_message_contains(user.pid, ~r/ 770 \* key/)
    end)
  end

  defp dispatch(user, params, trailing \\ nil) do
    Command.dispatch(user, %Message{command: "METADATA", params: params, trailing: trailing})
  end
end
