defmodule ElixIRCd.Commands.TraceTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Trace
  alias ElixIRCd.Message

  describe "handle/2" do
    test "handles TRACE command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "TRACE", params: ["#anything"]}

        assert :ok = Trace.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles TRACE command without target" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "TRACE", params: []}

        assert :ok = Trace.handle(user, message)

        assert_sent_messages([
          {user.pid, ~r{:irc\.test 205 #{user.nick} User users #{user.nick}\[.*\] \(255\.255\.255\.255\) \d+ \d+\r\n}},
          {user.pid, ":irc.test 262 #{user.nick} :End of TRACE\r\n"}
        ])
      end)
    end

    test "handles TRACE command with target user" do
      Memento.transaction!(fn ->
        user = insert(:user)

        insert(:user, nick: "target", modes: ["x"], hostname: "private.example", cloaked_hostname: "cloak.IP")

        message = %Message{command: "TRACE", params: ["target"]}

        assert :ok = Trace.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ~r{:irc\.test 205 #{user.nick} User users target\[target!.*@cloak\.IP\] \(255\.255\.255\.255\) \d+ \d+\r\n}},
          {user.pid, ":irc.test 262 #{user.nick} :End of TRACE\r\n"}
        ])
      end)
    end

    test "handles TRACE command with target user not existing" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "TRACE", params: ["target"]}

        assert :ok = Trace.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 401 #{user.nick} target :No such nick\r\n"}
        ])
      end)
    end

    test "includes the target IP in TRACE replies to IRC operators" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        insert(:user, nick: "target", modes: ["x"], cloaked_hostname: "cloak.IP")
        assert :ok = Trace.handle(user, %Message{command: "TRACE", params: ["target"]})
        assert_sent_message_contains(user.pid, ~r/\(127\.0\.0\.1\)/)
      end)
    end

    test "rejects TRACE command with a target user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user)
        insert(:user, nick: "target", registered: false, registered_at: nil)
        assert :ok = Trace.handle(user, %Message{command: "TRACE", params: ["target"]})
        assert_sent_messages([{user.pid, ":irc.test 401 #{user.nick} target :No such nick\r\n"}])
      end)
    end
  end
end
