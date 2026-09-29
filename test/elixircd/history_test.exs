defmodule ElixIRCd.HistoryTest do
  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.History
  alias ElixIRCd.History.RemoteIdentity
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChatHistory
  alias ElixIRCd.ServerLink.Directory
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.UserPayload

  test "parses every history reference form and ignores non-recordable input" do
    now = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    assert {:ok, :all} = History.parse_reference("*")
    assert {:ok, {:msgid, "one"}} = History.parse_reference("msgid=one")
    assert {:ok, {:timestamp, ^now}} = History.parse_reference("timestamp=" <> DateTime.to_iso8601(now))
    assert {:error, :invalid_reference} = History.parse_reference("timestamp=bad")
    assert {:error, :invalid_reference} = History.parse_reference("msgid=")
    assert :ok = History.record(%Message{command: "PING", params: []}, build(:user))
    assert nil == History.identity_key(%{build(:user) | pid: nil, nick: nil, created_at: nil})
  end

  test "queries all CHATHISTORY windows, including missing references" do
    Memento.transaction!(fn ->
      base = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.add(-10, :second)
      entries = Enum.map(0..4, &history_entry("channel:#test", "id#{&1}", DateTime.add(base, &1, :second)))

      assert Enum.map(History.query("channel:#test", "LATEST", :all, nil, 2), & &1.msgid) == ["id3", "id4"]

      assert Enum.map(History.query("channel:#test", "LATEST", {:msgid, "id1"}, nil, 2), & &1.msgid) == [
               "id3",
               "id4"
             ]

      assert Enum.map(History.query("channel:#test", "BEFORE", {:msgid, "id3"}, nil, 2), & &1.msgid) == [
               "id1",
               "id2"
             ]

      assert Enum.map(History.query("channel:#test", "AFTER", {:msgid, "id2"}, nil, 2), & &1.msgid) == [
               "id3",
               "id4"
             ]

      assert Enum.map(
               History.query("channel:#test", "BETWEEN", {:msgid, "id0"}, {:msgid, "id4"}, 10),
               & &1.msgid
             ) == ["id1", "id2", "id3"]

      assert Enum.map(
               History.query("channel:#test", "BETWEEN", {:msgid, "id4"}, {:msgid, "id0"}, 2),
               & &1.msgid
             ) == ["id2", "id3"]

      assert History.query("channel:#test", "BETWEEN", {:msgid, "id2"}, {:msgid, "id2"}, 10) == []
      assert History.query("channel:#test", "BETWEEN", :all, :all, 10) == []

      outside_low = {:timestamp, DateTime.add(base, -2, :second)}
      outside_high = {:timestamp, DateTime.add(base, 10, :second)}

      assert Enum.map(History.query("channel:#test", "BETWEEN", outside_low, outside_high, 10), & &1.msgid) ==
               Enum.map(entries, & &1.msgid)

      assert Enum.map(History.query("channel:#test", "LATEST", {:timestamp, base}, nil, 1), & &1.msgid) == ["id4"]

      assert Enum.map(History.query("channel:#test", "AROUND", {:msgid, "id2"}, nil, 3), & &1.msgid) == [
               "id1",
               "id2",
               "id3"
             ]

      assert History.query("channel:#test", "AROUND", {:msgid, "missing"}, nil, 3) == []
      assert History.query("channel:#test", "LATEST", {:msgid, "missing"}, nil, 3) == []

      ChatHistory.redact(Enum.at(entries, 2), DateTime.utc_now())

      assert Enum.map(History.query("channel:#test", "AFTER", {:msgid, "id2"}, nil, 2), & &1.msgid) == [
               "id3",
               "id4"
             ]

      assert Enum.map(History.query("channel:#test", "BEFORE", {:msgid, "id2"}, nil, 2), & &1.msgid) == [
               "id0",
               "id1"
             ]

      first = hd(entries)
      assert {:ok, ^first} = ChatHistory.get_by_msgid("id0")
      assert {:error, :history_not_found} = ChatHistory.get_by_msgid("absent")
      assert :ok = ChatHistory.delete(first)
    end)
  end

  test "lists only visible target activity inside exclusive bounds" do
    Memento.transaction!(fn ->
      alice = insert(:user, nick: "Alice", identified_as: "Alice")
      bob = insert(:user, nick: "Bob", identified_as: "Bob")
      channel = insert(:channel, name: "#test")
      insert(:user_channel, user: alice, channel: channel)

      base = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.add(-10, :second)
      history_entry("channel:#test", "channel", DateTime.add(base, 1, :second), target_name: "#test")

      history_entry("direct:one", "sent", DateTime.add(base, 2, :second),
        type: :direct,
        target_name: "Bob",
        sender: History.identity_key(alice),
        recipient: History.identity_key(bob)
      )

      history_entry("direct:two", "received", DateTime.add(base, 3, :second),
        type: :direct,
        target_name: "Alice",
        sender: History.identity_key(bob),
        recipient: History.identity_key(alice),
        message: %Message{command: "PRIVMSG", params: ["Alice"], prefix: "Bob!u@h"}
      )

      history_entry("direct:three", "multiline", DateTime.add(base, 4, :second),
        type: :direct,
        target_name: "Alice",
        sender: History.identity_key(bob),
        recipient: History.identity_key(alice),
        message: %{kind: :multiline, lines: [%Message{command: "PRIVMSG", params: ["Alice"], prefix: "Bob!u@h"}]}
      )

      hidden = history_entry("direct:hidden", "hidden", DateTime.add(base, 5, :second), type: :direct)
      ChatHistory.redact(hidden, DateTime.utc_now())

      assert Enum.map(ChatHistory.all(), & &1.msgid) == ["channel", "sent", "received", "multiline", "hidden"]

      assert Enum.map(History.targets_for_request(alice, :all, :all, 10), &elem(&1, 0)) == [
               "#test",
               "Bob",
               "Bob",
               "Bob"
             ]

      lower = {:timestamp, DateTime.add(base, 1, :second)}
      upper = {:timestamp, DateTime.add(base, 4, :second)}
      assert Enum.map(History.targets_for_request(alice, lower, upper, 10), &elem(&1, 0)) == ["Bob", "Bob"]

      anonymous = build(:user, pid: nil, nick: nil, created_at: nil)
      assert History.targets_for_request(anonymous, :all, :all, 10) == []
    end)
  end

  test "uses the stable message order to select a target's latest message when timestamps tie" do
    Memento.transaction!(fn ->
      alice = insert(:user, nick: "Alice", identified_as: "Alice")
      bob = insert(:user, nick: "Bob", identified_as: "Bob")
      timestamp = DateTime.utc_now() |> DateTime.truncate(:millisecond)

      history_entry("direct:opaque", "opaque", DateTime.add(timestamp, -1, :second),
        type: :direct,
        target_name: "Fallback",
        sender: History.identity_key(bob),
        recipient: History.identity_key(alice),
        message: %{kind: :opaque}
      )

      for {msgid, target_name} <- [{"a", "Earlier"}, {"z", "Latest"}] do
        history_entry("direct:tie", msgid, timestamp,
          type: :direct,
          target_name: target_name,
          sender: History.identity_key(alice)
        )
      end

      newer = {:timestamp, DateTime.add(timestamp, 1, :second)}
      older = {:timestamp, DateTime.add(timestamp, -2, :second)}
      assert History.targets_for_request(alice, newer, older, 1) == [{"Latest", timestamp}]

      assert Enum.map(History.targets_for_request(alice, :all, :all, 2), &elem(&1, 0)) == [
               "Fallback",
               "Latest"
             ]
    end)
  end

  test "resolves offline registered direct targets and rejects missing message targets" do
    Memento.transaction!(fn ->
      alice = insert(:user, nick: "Alice", identified_as: "Alice")
      insert(:registered_nick, nickname: "Offline", account_name: "Offline")

      assert {:ok, %{type: :direct, name: "Offline"}} = History.target_for_request(alice, "Offline")
      assert {:error, :invalid_target} = History.target_for_request(alice, "Missing")

      assert :ok =
               History.record(
                 %Message{
                   command: "PRIVMSG",
                   params: [],
                   tags: %{"msgid" => "missing", "time" => DateTime.to_iso8601(DateTime.utc_now())}
                 },
                 alice
               )
    end)
  end

  test "resolves a connected remote target by UID before a same-named local registration" do
    prior_links = Application.fetch_env!(:elixircd, :server_links)
    Application.put_env(:elixircd, :server_links, Keyword.put(prior_links, :enabled, true))
    on_exit(fn -> Application.put_env(:elixircd, :server_links, prior_links) end)

    table = Directory.create()
    origin = "east.example"
    uid = UserPayload.new_uid()
    remote_user = build(:user, nick: "Remote") |> UserPayload.from_local(uid)

    replica = %Replica{
      users: %{{origin, uid} => remote_user},
      nick_keys: %{"remote" => {origin, uid}}
    }

    Directory.sync(table, Replica.new(), replica)

    Memento.transaction!(fn ->
      local = insert(:user, nick: "Local")
      insert(:registered_nick, nickname: "Remote", account_name: "LocalAccount")
      remote = %RemoteIdentity{origin: origin, uid: uid, nick: "Remote"}
      identities = [History.identity_key(local), History.remote_identity_key(remote)] |> Enum.sort()

      assert {:ok, %{type: :direct, key: key}} = History.target_for_request(local, "Remote")
      assert key == "direct:" <> Enum.join(identities, "\0")

      timestamp = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

      assert :ok =
               History.record_remote_outgoing(
                 %Message{
                   command: "PRIVMSG",
                   params: ["Remote"],
                   trailing: "hello",
                   tags: %{"msgid" => "out", "time" => timestamp}
                 },
                 local,
                 remote
               )

      assert :ok =
               History.record_remote_incoming(
                 %Message{
                   command: "NOTICE",
                   params: ["Local"],
                   trailing: "reply",
                   tags: %{"msgid" => "in", "time" => timestamp}
                 },
                 remote,
                 local
               )

      assert History.query(key, "LATEST", :all, nil, 10) |> Enum.map(& &1.msgid) == ["in", "out"]

      Directory.sync(table, replica, Replica.new())
      assert {:ok, %{key: local_key}} = History.target_for_request(local, "Remote")
      refute local_key == key
    end)
  end

  test "uses msgid as a stable cursor when timestamps tie and excludes expired entries before pagination" do
    Memento.transaction!(fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:millisecond)
      timestamp = DateTime.add(now, -2, :second)
      Enum.each(["a", "b", "c"], &history_entry("channel:#test", &1, timestamp))

      assert Enum.map(History.query("channel:#test", "AFTER", {:msgid, "a"}, nil, 2), & &1.msgid) == ["b", "c"]
      assert Enum.map(History.query("channel:#test", "BEFORE", {:msgid, "c"}, nil, 2), & &1.msgid) == ["a", "b"]

      assert Enum.map(
               History.query("channel:#test", "AROUND", {:timestamp, DateTime.add(now, 10, :second)}, nil, 2),
               & &1.msgid
             ) == ["b", "c"]

      old = history_entry("channel:#test", "old", DateTime.add(now, -10, :day))
      assert Enum.map(History.query("channel:#test", "LATEST", :all, nil, 10), & &1.msgid) == ["a", "b", "c"]
      assert History.prune_expired(now) == 1
      assert {:error, :history_not_found} = ChatHistory.get_by_msgid(old.msgid)
    end)
  end

  test "compares event msgid bounds even when event playback is disabled" do
    Memento.transaction!(fn ->
      base = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.add(-5, :second)
      event = %Message{command: "TOPIC", params: ["#test"], prefix: "Alice!u@h"}
      history_entry("channel:#test", "event-a", base, message: event)
      history_entry("channel:#test", "message", DateTime.add(base, 1, :second))
      history_entry("channel:#test", "event-b", DateTime.add(base, 2, :second), message: event)

      assert Enum.map(
               History.query("channel:#test", "BETWEEN", {:msgid, "event-a"}, {:msgid, "event-b"}, 5, false),
               & &1.msgid
             ) == ["message"]
    end)
  end

  defp history_entry(target_key, msgid, occurred_at, opts \\ []) do
    message = Keyword.get(opts, :message, %Message{command: "PRIVMSG", params: ["#test"], prefix: "Alice!u@h"})

    ChatHistory.create(%{
      id: {target_key, DateTime.to_unix(occurred_at, :microsecond), msgid},
      target_type: Keyword.get(opts, :type, :channel),
      target_key: target_key,
      target_name: Keyword.get(opts, :target_name, "#test"),
      msgid: msgid,
      sender_account_key: Keyword.get(opts, :sender),
      recipient_account_key: Keyword.get(opts, :recipient),
      message: message,
      occurred_at: occurred_at
    })
  end
end
