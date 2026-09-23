defmodule ElixIRCd.Commands.SquitTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Squit
  alias ElixIRCd.Message
  alias ElixIRCd.Server.S2S.Manager

  test "requires registration, parameters and operator privileges" do
    Memento.transaction!(fn ->
      user = insert(:user, registered: false)
      assert :ok = Squit.handle(user, %Message{command: "SQUIT", params: ["leaf"]})
      assert_sent_messages([{user.pid, ":irc.test 451 * :You have not registered\r\n"}])
    end)

    Memento.transaction!(fn ->
      user = insert(:user)
      assert :ok = Squit.handle(user, %Message{command: "SQUIT", params: []})

      assert_sent_messages([
        {user.pid, ":irc.test 461 #{user.nick} SQUIT :Not enough parameters\r\n"}
      ])
    end)

    Memento.transaction!(fn ->
      user = insert(:user)
      assert :ok = Squit.handle(user, %Message{command: "SQUIT", params: ["leaf"]})

      assert_sent_messages([
        {user.pid, ":irc.test 481 #{user.nick} :Permission Denied- You're not an IRC operator\r\n"}
      ])
    end)
  end

  test "closes and disables only the configured direct edge" do
    manager = start_manager()

    Memento.transaction!(fn ->
      user = insert(:user, modes: [:o])

      assert :ok =
               Squit.handle(user, %Message{
                 command: "SQUIT",
                 params: ["leaf"],
                 trailing: "maintenance"
               })

      assert_sent_messages([
        {user.pid, ":irc.test NOTICE #{user.nick} :SQUIT closed and disabled leaf\r\n"}
      ])
    end)

    assert {:ok, :awaiting_child} = Manager.connect_neighbor(manager, "leaf")

    Memento.transaction!(fn ->
      user = insert(:user, modes: [:o])
      assert :ok = Squit.handle(user, %Message{command: "SQUIT", params: ["unknown"]})

      assert_sent_messages([
        {user.pid, ":irc.test 402 #{user.nick} unknown :No such server\r\n"}
      ])
    end)
  end

  defp start_manager do
    {:ok, manager} = Manager.start_link(config: config(), name: Manager)
    Process.unlink(manager)

    on_exit(fn ->
      if Process.alive?(manager), do: GenServer.stop(manager)
    end)

    manager
  end

  defp config do
    [
      s2s: [
        enabled: true,
        network_id: "squit-command-test",
        semantic_revision: 1,
        server_id: "root",
        server_name: "root.example.test",
        services_authority: nil,
        roster: [
          [sid: "root", name: "root.example.test", parent: nil],
          [sid: "leaf", name: "leaf.example.test", parent: "root"]
        ],
        children: %{"leaf" => [pins: [String.duplicate("a", 64)], ips: []]},
        parent_connection: nil,
        timeouts: [heartbeat_ms: 60_000, heartbeat_timeout_ms: 60_000],
        budgets: [max_pending_requests_origin: 128]
      ],
      settings: [case_mapping: :ascii, utf8_only: true]
    ]
  end
end
