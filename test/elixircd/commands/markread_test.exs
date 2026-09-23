defmodule ElixIRCd.Commands.MarkreadTest do
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Command
  alias ElixIRCd.Message
  alias ElixIRCd.ReadMarkers
  alias ElixIRCd.Repositories.ReadMarkers, as: MarkerRepository
  alias ElixIRCd.Repositories.Users

  test "stores a monotonic marker and propagates it to another account session" do
    Memento.transaction!(fn ->
      first = insert(:user, nick: "Alice", identified_as: "Alice", capabilities: ["draft/read-marker"])
      second = insert(:user, nick: "Alice2", identified_as: "Alice", capabilities: ["draft/read-marker"])
      channel = insert(:channel, name: "#test")
      insert(:user_channel, user: first, channel: channel)

      set = %Message{command: "MARKREAD", params: ["#test", "timestamp=2022-11-11T11:11:11.111Z"]}
      assert :ok = Command.dispatch(first, set)

      expected = ":irc.test MARKREAD #test timestamp=2022-11-11T11:11:11.111Z\r\n"
      assert_sent_messages([{first.pid, expected}, {second.pid, expected}])

      older = %Message{command: "MARKREAD", params: ["#test", "timestamp=2020-01-01T00:00:00.000Z"]}
      assert :ok = Command.dispatch(first, older)
      assert_sent_messages([{first.pid, expected}, {second.pid, expected}])

      assert :ok = Command.dispatch(first, %Message{command: "MARKREAD", params: ["#test"]})
      assert_sent_messages([{first.pid, expected}])
    end)
  end

  test "returns wildcard when absent and rejects malformed client timestamps" do
    Memento.transaction!(fn ->
      user = insert(:user, nick: "Alice", capabilities: ["draft/read-marker"])
      channel = insert(:channel, name: "#test")
      insert(:user_channel, user: user, channel: channel)
      assert :ok = Command.dispatch(user, %Message{command: "MARKREAD", params: ["#missing"]})
      assert_sent_messages([{user.pid, ":irc.test MARKREAD #missing *\r\n"}])

      assert :ok = Command.dispatch(user, %Message{command: "MARKREAD", params: ["#missing", "*"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL MARKREAD INVALID_PARAMS /)
    end)
  end

  test "validates capabilities, parameters and marker ownership" do
    Memento.transaction!(fn ->
      unavailable = insert(:user, nick: "NoCap")
      assert :ok = Command.dispatch(unavailable, %Message{command: "MARKREAD", params: ["#test"]})
      assert_sent_message_contains(unavailable.pid, ~r/ FAIL MARKREAD NEED_CAP/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok =
               Command.dispatch(unavailable, %Message{
                 command: "MARKREAD",
                 params: ["#test", "timestamp=2026-01-01T00:00:00Z"]
               })

      assert_sent_message_contains(unavailable.pid, ~r/ FAIL MARKREAD NEED_CAP/)

      user = insert(:user, nick: "Alice", capabilities: ["draft/read-marker"])
      channel = insert(:channel, name: "#test")
      insert(:user_channel, user: user, channel: channel)
      assert :ok = Command.dispatch(user, %Message{command: "MARKREAD", params: []})
      assert_sent_message_contains(user.pid, ~r/ FAIL MARKREAD NEED_MORE_PARAMS/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = Command.dispatch(user, %Message{command: "MARKREAD", params: ["#test", "other"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL MARKREAD INVALID_PARAMS/)
      assert :ok = Command.dispatch(user, %Message{command: "MARKREAD", params: ["#test", "timestamp=bad"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL MARKREAD INVALID_PARAMS/)

      no_identity = %{user | pid: nil, nick: nil, created_at: nil}
      assert {:error, :invalid_owner} = ReadMarkers.set(no_identity, "#test", DateTime.utc_now())

      now = DateTime.utc_now() |> DateTime.truncate(:millisecond)
      assert {:ok, ^now} = ReadMarkers.set(user, "#test", now)
      assert {:ok, ^now} = ReadMarkers.set(user, "#test", now)
    end)
  end

  test "rejects arbitrary targets, caps stored targets, and clamps future timestamps" do
    Memento.transaction!(fn ->
      user = insert(:user, nick: "Alice", identified_as: "Alice", capabilities: ["draft/read-marker"])
      insert(:user, nick: "Bob")
      insert(:registered_nick, nickname: "Offline")
      channel = insert(:channel, name: "#test")
      insert(:user_channel, user: user, channel: channel)
      now = DateTime.utc_now()

      assert {:ok, _} = ReadMarkers.set(user, "Missing", now)
      assert {:error, :invalid_target} = ReadMarkers.set(user, "bad target", now)
      assert {:error, :invalid_target} = ReadMarkers.set(user, "#bad,channel", now)
      assert {:error, :invalid_target} = ReadMarkers.set(user, nil, now)
      assert {:ok, _} = ReadMarkers.set(user, "Bob", now)
      assert {:ok, _} = ReadMarkers.set(user, "Offline", now)
      assert {:ok, clamped} = ReadMarkers.set(user, "#test", DateTime.add(now, 1, :day))
      assert DateTime.compare(clamped, DateTime.utc_now()) != :gt

      owner = ReadMarkers.owner_key(user)

      for index <- 1..252 do
        MarkerRepository.put(owner, "#old#{index}", "#old#{index}", now)
      end

      assert MarkerRepository.count_owner(owner) == 256
      another = insert(:channel, name: "#another")
      insert(:user_channel, user: user, channel: another)
      assert {:error, :target_limit} = ReadMarkers.set(user, "#another", now)
      assert {:ok, _} = ReadMarkers.set(user, "#test", now)
    end)
  end

  test "removes abandoned session markers while retaining account markers" do
    Memento.transaction!(fn ->
      session = insert(:user, nick: "Session")
      session_owner = ReadMarkers.owner_key(session)
      account_owner = "account:alice"
      now = DateTime.utc_now()
      old = DateTime.add(now, -2, :day)

      for owner <- [session_owner, account_owner] do
        marker = MarkerRepository.put(owner, "#old", "#old", now)
        Memento.Query.write(%{marker | updated_at: old})
      end

      assert :ok = MarkerRepository.prune_abandoned_sessions(DateTime.add(now, -1, :day), MapSet.new())
      assert {:error, :read_marker_not_found} = MarkerRepository.get(session_owner, "#old")
      assert {:ok, _} = MarkerRepository.get(account_owner, "#old")

      MarkerRepository.put(session_owner, "#current", "#current", now)
      assert :ok = MarkerRepository.delete_owner(session_owner)
      assert {:error, :read_marker_not_found} = MarkerRepository.get(session_owner, "#current")
    end)
  end

  test "moves anonymous markers to the account on authentication and preserves newer values" do
    Memento.transaction!(fn ->
      anonymous = insert(:user, nick: "Alice")
      session_owner = ReadMarkers.owner_key(anonymous)
      account_owner = "account:alice"
      old = DateTime.utc_now() |> DateTime.add(-2, :hour)
      newer = DateTime.add(old, 1, :hour)

      assert {:ok, _} = ReadMarkers.set(anonymous, "#new", newer)
      assert {:ok, _} = ReadMarkers.set(anonymous, "#shared", old)
      MarkerRepository.put(account_owner, "#shared", "#shared", newer)

      authenticated = Users.update(anonymous, %{identified_as: "Alice"})
      assert ReadMarkers.get(authenticated, "#new") == newer
      assert ReadMarkers.get(authenticated, "#shared") == newer
      assert MarkerRepository.count_owner(session_owner) == 0

      assert {:ok, _} = ReadMarkers.set(anonymous, "#older", old)
      MarkerRepository.put(account_owner, "#older", "#older", old)
      Users.update(anonymous, %{identified_as: "Alice"})
      assert {:ok, _} = MarkerRepository.get(account_owner, "#older")

      assert {:ok, _} = ReadMarkers.set(anonymous, "#shared", DateTime.utc_now())
      updated = Users.update(anonymous, %{identified_as: "Alice"})
      assert DateTime.compare(ReadMarkers.get(updated, "#shared"), newer) == :gt
    end)
  end

  test "does not exceed the per-account target limit when merging session markers" do
    Memento.transaction!(fn ->
      anonymous = insert(:user, nick: "Alice")
      now = DateTime.utc_now()
      assert {:ok, _} = ReadMarkers.set(anonymous, "#overflow", now)

      for index <- 1..256 do
        MarkerRepository.put("account:alice", "#existing#{index}", "#existing#{index}", now)
      end

      Users.update(anonymous, %{identified_as: "Alice"})
      assert MarkerRepository.count_owner("account:alice") == 256
      assert {:error, :read_marker_not_found} = MarkerRepository.get("account:alice", "#overflow")
      assert MarkerRepository.count_owner(ReadMarkers.owner_key(anonymous)) == 0
    end)
  end
end
