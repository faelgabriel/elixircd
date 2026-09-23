defmodule ElixIRCd.Commands.LinksTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Links
  alias ElixIRCd.Message
  alias ElixIRCd.Server.S2S.Manager

  test "returns a topology-redacted LINKS response" do
    Memento.transaction!(fn ->
      user = insert(:user)

      assert :ok = Links.handle(user, %Message{command: "LINKS", params: []})

      assert_sent_messages([
        {user.pid, ":irc.test 365 #{user.nick} * :End of /LINKS list\r\n"}
      ])
    end)
  end

  test "requires registration" do
    Memento.transaction!(fn ->
      user = insert(:user, registered: false)
      assert :ok = Links.handle(user, %Message{command: "LINKS", params: []})
      assert_sent_messages([{user.pid, ":irc.test 451 * :You have not registered\r\n"}])
    end)
  end

  test "reports reachable configured nodes and applies the requested mask" do
    manager = start_manager()

    Memento.transaction!(fn ->
      user = insert(:user)
      assert :ok = Links.handle(user, %Message{command: "LINKS", params: ["root"]})

      assert_sent_messages([
        {user.pid, ":irc.test 364 #{user.nick} root.example.test * 0 :ENP/1 #{Manager.status(manager).sid}\r\n"},
        {user.pid, ":irc.test 365 #{user.nick} root :End of /LINKS list\r\n"}
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
        network_id: "links-command-test",
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
