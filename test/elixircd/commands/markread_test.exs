defmodule ElixIRCd.Commands.MarkreadTest do
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Command
  alias ElixIRCd.Message
  alias ElixIRCd.ReadMarkers

  test "stores a monotonic marker and propagates it to another account session" do
    Memento.transaction!(fn ->
      first = insert(:user, nick: "Alice", identified_as: "Alice", capabilities: ["draft/read-marker"])
      second = insert(:user, nick: "Alice2", identified_as: "Alice", capabilities: ["draft/read-marker"])

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
end
