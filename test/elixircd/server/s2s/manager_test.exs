defmodule ElixIRCd.Server.S2S.ManagerTest.FakeSession do
  use GenServer

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

  @impl true
  def init(parent), do: {:ok, parent}

  @impl true
  def handle_call({:send_frame, frame}, _from, parent) do
    send(parent, {:frame, frame})
    {:reply, :ok, parent}
  end

  def handle_call({:enqueue_frame, frame}, _from, parent) do
    send(parent, {:frame, frame})
    {:reply, :ok, parent}
  end

  def handle_call(_request, _from, parent), do: {:reply, :ok, parent}

  @impl true
  def handle_cast({:enqueue_frame, frame}, parent) do
    send(parent, {:frame, frame})
    {:noreply, parent}
  end

  def handle_cast({:close, code, reason}, parent) do
    send(parent, {:closed, code, reason})
    {:noreply, parent}
  end

  def handle_cast(_message, parent), do: {:noreply, parent}
end

defmodule ElixIRCd.Server.S2S.ManagerTest do
  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.JSON
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.ManagerTest.FakeSession
  alias ElixIRCd.Server.S2S.Output
  alias ElixIRCd.Server.S2S.Profile
  alias ElixIRCd.Server.S2S.Requests
  alias ElixIRCd.Server.S2S.Sync

  defp config do
    [
      s2s: [
        enabled: true,
        network_id: "test-net",
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

  test "admits a pinned configured child and fences its topology generation" do
    {:ok, manager} = Manager.start_link(config: config())
    Process.unlink(manager)

    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    local_hello = Manager.local_hello(manager)

    assert %{sid: "root"} =
             local_hello
             |> Map.take(["sid"])
             |> Map.new(fn {key, value} -> {String.to_atom(key), value} end)

    peer_info = %{address: {192, 0, 2, 10}, port: 7000, certfp: String.duplicate("a", 64)}
    assert {:ok, %{sid: "leaf"}} = Manager.admit_peer(manager, :incoming, peer_info)

    generation = Identity.nonce()

    assert {:ok, ^generation} =
             Manager.register_session(manager, self(), %{
               direction: :incoming,
               peer_sid: "leaf",
               peer_name: "leaf.example.test",
               peer_info: peer_info,
               owner: self(),
               generation: generation,
               local_hello: local_hello
             })

    remote_config =
      config()
      |> put_in([:s2s, :server_id], "leaf")
      |> put_in([:s2s, :server_name], "leaf.example.test")

    remote = Profile.hello(remote_config, Identity.boot(), Identity.nonce())
    assert :ok = Manager.admit_hello(manager, self(), remote)
    assert {:ok, edge_id} = Identity.edge_id(local_hello, remote)
    assert %{edge_id: ^edge_id, local_hello: ^local_hello} = :sys.get_state(manager).sessions[self()]
    assert %{reachable_sids: ["root"]} = Manager.status(manager)

    delivery_ref = make_ref()
    send(manager, {:s2s_session_event, self(), generation, {:send_error, :test}, self(), peer_info, delivery_ref})
    assert_receive {:s2s_manager_event_ack, ^delivery_ref, :ok}, 500
    assert eventually(fn -> not Map.has_key?(:sys.get_state(manager).sessions, self()) end)
    assert %{reachable_sids: ["root"], last_link_error: "send_error"} = Manager.status(manager)
  end

  test "rejects a valid CA certificate whose fingerprint is not configured" do
    {:ok, manager} = Manager.start_link(config: config())
    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    assert {:error, :peer_certificate_not_pinned} =
             Manager.admit_peer(manager, :incoming, %{
               certfp: String.duplicate("b", 64),
               address: {192, 0, 2, 11},
               port: 7000
             })
  end

  test "builds a fresh timestamped hello for every native session" do
    {:ok, manager} = Manager.start_link(config: config())
    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    first = Manager.local_hello(manager)
    second = Manager.local_hello(manager)
    now = Identity.now_ms()

    assert first["nonce"] != second["nonce"]
    assert first["time_ms"] in (now - 5_000)..now
    assert second["time_ms"] in (now - 5_000)..now
    assert first["profile_hash"] == second["profile_hash"]
    assert first["sid"] == second["sid"]
    assert first["boot"] == second["boot"]
  end

  test "prepares an admitted link snapshot in a fenced worker" do
    parent = self()
    {:ok, manager} = Manager.start_link(config: config())
    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    peer_info = %{address: {192, 0, 2, 13}, port: 7000, certfp: String.duplicate("a", 64)}
    assert {:ok, _peer} = Manager.admit_peer(manager, :incoming, peer_info)
    local_hello = Manager.local_hello(manager)
    {:ok, session} = FakeSession.start_link(parent)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    generation = Identity.nonce()

    assert {:ok, ^generation} =
             Manager.register_session(manager, session, %{
               direction: :incoming,
               peer_sid: "leaf",
               peer_name: "leaf.example.test",
               peer_info: peer_info,
               owner: session,
               generation: generation,
               local_hello: local_hello
             })

    remote_config =
      config()
      |> put_in([:s2s, :server_id], "leaf")
      |> put_in([:s2s, :server_name], "leaf.example.test")

    remote = Profile.hello(remote_config, Identity.boot(), Identity.nonce())
    assert :ok = Manager.admit_hello(manager, session, remote)
    assert :ok = Manager.session_event(manager, session, {:hello, remote})

    assert_receive {:frame, %{"t" => "sync", "phase" => "begin"}}, 1_000
    assert eventually(fn -> Manager.status(manager).pending_snapshot_jobs == 0 end)
  end

  test "a snapshot is followed by every state change after its captured cut" do
    parent = self()

    capture_fun = fn sync_id, cut, projections ->
      send(parent, {:sync_capture_blocked, self(), cut})

      receive do
        :continue_sync_capture -> Sync.capture(sync_id, cut, projections)
      after
        5_000 -> {:error, :sync_capture_test_timeout}
      end
    end

    {:ok, manager} = Manager.start_link(config: config(), sync_capture_fun: capture_fun)
    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    peer_info = %{address: {192, 0, 2, 15}, port: 7000, certfp: String.duplicate("a", 64)}
    assert {:ok, _peer} = Manager.admit_peer(manager, :incoming, peer_info)
    local_hello = Manager.local_hello(manager)
    {:ok, session} = FakeSession.start_link(parent)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    generation = Identity.nonce()

    assert {:ok, ^generation} =
             Manager.register_session(manager, session, %{
               direction: :incoming,
               peer_sid: "leaf",
               peer_name: "leaf.example.test",
               peer_info: peer_info,
               owner: session,
               generation: generation,
               local_hello: local_hello
             })

    remote_config =
      config()
      |> put_in([:s2s, :server_id], "leaf")
      |> put_in([:s2s, :server_name], "leaf.example.test")

    remote = Profile.hello(remote_config, Identity.boot(), Identity.nonce())
    assert :ok = Manager.admit_hello(manager, session, remote)
    assert :ok = Manager.session_event(manager, session, {:hello, remote})

    channel = %{"name" => "#postcut", "born_ms" => 1, "cid" => Identity.cid()}
    ensure = %{"kind" => "channel.ensure", "channel" => channel}
    uid = Identity.uid()
    home = %{"sid" => "root", "boot" => local_hello["boot"]}

    user = %{
      "uid" => uid,
      "home" => home,
      "rev" => 1,
      "requested_nick" => "PostCut",
      "signon_ms" => 1,
      "ident" => "test",
      "realhost" => "postcut.example.test",
      "displayhost" => "postcut.example.test",
      "address" => "192.0.2.15",
      "secure_client" => true,
      "client_certfp" => nil,
      "modes" => [],
      "oper_role" => nil,
      "away" => nil,
      "realname" => "post-cut snapshot test",
      "binding" => nil
    }

    user_put = %{"kind" => "user.put", "user" => user}
    joined = %{"channel" => "#postcut", "join_id" => 1, "joined_ms" => 1}
    actor = %{"user" => uid}

    membership_join = %{
      "kind" => "memberships.put",
      "uid" => uid,
      "home" => home,
      "rev" => 1,
      "entries" => [joined],
      "cause" => %{"action" => "join", "channel" => "#postcut", "join_id" => 1, "by" => actor, "reason" => "join"}
    }

    topic_stamp = Output.next_stamp("root", local_hello["boot"])

    topic = %{
      "kind" => "channel.field",
      "channel" => channel,
      "field" => "topic",
      "value" => %{"text" => "after snapshot cut", "setter" => "root", "set_ms" => 1},
      "stamp" => topic_stamp,
      "setter" => actor
    }

    renamed_user = %{user | "rev" => 2, "requested_nick" => "RenamedPostCut"}
    nick = %{"kind" => "user.put", "user" => renamed_user}

    membership_part = %{
      "kind" => "memberships.put",
      "uid" => uid,
      "home" => home,
      "rev" => 2,
      "entries" => [],
      "cause" => %{"action" => "part", "channel" => "#postcut", "join_id" => 1, "by" => actor, "reason" => "part"}
    }

    quit = %{
      "kind" => "user.quit",
      "uid" => uid,
      "home" => home,
      "rev" => 3,
      "reason" => "quit after snapshot cut",
      "action" => "quit",
      "by" => %{"server" => "root"}
    }

    post_cut_rows = [ensure, user_put, membership_join, topic, nick, membership_part, quit]
    assert_receive {:sync_capture_blocked, sync_worker, captured_cut}, 1_000

    Enum.each(post_cut_rows, fn row ->
      assert :ok = Manager.publish_row(manager, row)
    end)

    assert captured_cut > 0
    send(sync_worker, :continue_sync_capture)

    assert_receive {:frame, %{"t" => "sync", "phase" => "begin"}}, 1_000
    assert_receive {:frame, %{"t" => "sync", "phase" => "rows", "rows" => snapshot_rows}}, 1_000
    assert_receive {:frame, %{"t" => "sync", "phase" => "end"}}, 1_000

    refute Enum.any?(snapshot_rows, &(&1["kind"] == "channel.ensure" and &1["channel"]["name"] == "#postcut"))
    refute Enum.any?(snapshot_rows, &(&1["kind"] == "user.put" and &1["user"]["uid"] == uid))
    assert :ok = Manager.session_event(manager, session, :active)

    for row <- post_cut_rows do
      assert_receive {:frame, %{"t" => "state", "changes" => [^row]}}, 1_000
    end

    assert eventually(fn -> Manager.status(manager).pending_snapshot_jobs == 0 end)
  end

  test "a snapshot cut excludes queued pre-cut chat and rows already in the snapshot" do
    parent = self()
    {:ok, manager} = Manager.start_link(config: config())
    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    peer_info = %{address: {192, 0, 2, 14}, port: 7000, certfp: String.duplicate("a", 64)}
    assert {:ok, _peer} = Manager.admit_peer(manager, :incoming, peer_info)
    local_hello = Manager.local_hello(manager)
    {:ok, session} = FakeSession.start_link(parent)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    generation = Identity.nonce()

    assert {:ok, ^generation} =
             Manager.register_session(manager, session, %{
               direction: :incoming,
               peer_sid: "leaf",
               peer_name: "leaf.example.test",
               peer_info: peer_info,
               owner: session,
               generation: generation,
               local_hello: local_hello
             })

    channel = %{"name" => "#precut", "born_ms" => 1, "cid" => Identity.cid()}
    row = %{"kind" => "channel.ensure", "channel" => channel}
    assert :ok = Manager.publish_row(manager, row)

    :sys.replace_state(manager, fn state ->
      record = state.sessions[session]
      old_message = %{"t" => "message", "n" => 1, "command" => "PRIVMSG", "text" => "before snapshot cut"}
      record = %{record | pending: [old_message | record.pending], pending_bytes: record.pending_bytes + 64}
      %{state | sessions: Map.put(state.sessions, session, record)}
    end)

    remote_config =
      config()
      |> put_in([:s2s, :server_id], "leaf")
      |> put_in([:s2s, :server_name], "leaf.example.test")

    remote = Profile.hello(remote_config, Identity.boot(), Identity.nonce())
    assert :ok = Manager.admit_hello(manager, session, remote)
    assert :ok = Manager.session_event(manager, session, {:hello, remote})

    assert_receive {:frame, %{"t" => "sync", "phase" => "begin"}}, 1_000
    assert_receive {:frame, %{"t" => "sync", "phase" => "rows", "rows" => rows}}, 1_000
    assert_receive {:frame, %{"t" => "sync", "phase" => "end"}}, 1_000

    assert Enum.count(rows, &(&1["kind"] == "channel.ensure" and &1["channel"]["name"] == "#precut")) == 1
    assert eventually(fn -> Manager.status(manager).pending_snapshot_jobs == 0 end)
    assert Manager.status(manager).pending_link_frames == 0
    refute_receive {:frame, %{"t" => "message", "text" => "before snapshot cut"}}, 100
    refute_receive {:frame, %{"t" => "state", "changes" => [%{"kind" => "channel.ensure"}]}}, 100
  end

  test "fences uncertain output and reports the link as unsafe" do
    {:ok, manager} = Manager.start_link(config: config())
    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    send(manager, {:s2s_output_uncertain, %{sequence: 1}, :writer_lost})

    assert eventually(fn ->
             status = Manager.status(manager)
             status.connector_error == "uncertain output: writer_lost" and not status.retry_blocked?
           end)
  end

  test "closes only the routed link for a target-scoped uncertain output" do
    {manager, session, _remote} = active_child()
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    result =
      Output.transaction(
        fn ->
          assert :ok = Output.collect_intent(%{kind: :s2s_request, target_sid: "leaf"})
          :committed
        end,
        drain_fun: fn _intent -> {:error, :writer_lost} end,
        on_drain_error: fn group, reason -> send(manager, {:s2s_output_uncertain, group, reason}) end
      )

    assert result == {:error, {:output_drain_failed, :writer_lost}}

    assert_receive {:closed, "TRANSPORT", "uncertain output: writer_lost"}, 1_000
    assert eventually(fn -> Manager.status(manager).connector_error == "uncertain output: writer_lost" end)
    assert eventually(fn -> Output.pending_groups() == [] end)
  end

  test "fences a committed output group from an interrupted manager generation on startup" do
    {:ok, manager} = Manager.start_link(config: config())
    Process.unlink(manager)

    assert {:ok, :committed, group} =
             Output.transaction_deferred(fn ->
               assert :ok = Output.collect_intent(%{kind: :s2s_request, target_sid: "leaf"})
               :committed
             end)

    assert group.destinations == [{:s2s_target, "leaf"}]
    assert [%{sequence: sequence}] = Output.pending_groups()
    assert sequence == group.sequence

    Process.exit(manager, :kill)
    assert eventually(fn -> not Process.alive?(manager) end)

    {:ok, replacement} = Manager.start_link(config: config())
    Process.unlink(replacement)
    on_exit(fn -> if Process.alive?(replacement), do: GenServer.stop(replacement) end)

    assert Output.pending_groups() == []
  end

  test "acknowledges an administrative lifecycle action before beginning bounded shutdown" do
    parent = self()

    shutdown_config = put_in(config(), [:s2s, :timeouts, :shutdown_ms], 100)

    {:ok, manager} =
      Manager.start_link(
        config: shutdown_config,
        lifecycle_fun: fn action, reason -> send(parent, {:lifecycle, action, reason}) end
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    send(manager, {:s2s_admin_lifecycle, "shutdown", "maintenance"})

    assert_receive {:lifecycle, "shutdown", "maintenance"}, 1_000
    assert Manager.status(manager).lifecycle == :closing
  end

  test "authorizes the configured default remote shutdown and reports acceptance first" do
    parent = self()
    boot = Identity.boot()
    uid = Identity.uid()

    insert(:user,
      uid: uid,
      pid: self(),
      nick: "Operator",
      home_sid: "root",
      home_boot: boot,
      modes: [:o],
      registered: true
    )

    configured =
      config()
      |> put_in([:s2s, :boot], boot)
      |> put_in([:s2s, :remote_admin],
        enabled: true,
        actions: [:shutdown],
        origin_sids: ["root"],
        operator_roles: ["oper"]
      )
      |> put_in([:s2s, :timeouts, :shutdown_ms], 100)

    {:ok, manager} =
      Manager.start_link(
        config: configured,
        reply_fun: fn result -> send(parent, {:admin_reply, result}) end,
        lifecycle_fun: fn action, reason -> send(parent, {:lifecycle, action, reason}) end
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    args = %{"action" => "shutdown", "neighbor_sid" => nil, "reason" => "maintenance"}

    guards = %{
      "actor_uid" => nil,
      "actor_user_rev" => nil,
      "actor_join_id" => nil,
      "target_user_rev" => nil,
      "target_join_id" => nil,
      "channel" => nil,
      "policy_epoch" => nil,
      "policy_revision" => nil
    }

    assert {:ok, _request_id} = Manager.request(manager, "root", %{"user" => uid}, "admin", args, guards)
    assert_receive {:admin_reply, %{status: "OK", done: true, payload: %{"result" => %{"accepted" => true}}}}, 1_000
    assert_receive {:lifecycle, "shutdown", "maintenance"}, 1_000
  end

  test "runs remote rehash outside the manager ordering process" do
    parent = self()
    boot = Identity.boot()
    uid = Identity.uid()

    insert(:user,
      uid: uid,
      pid: self(),
      nick: "Operator",
      home_sid: "root",
      home_boot: boot,
      modes: [:o],
      registered: true
    )

    configured =
      config()
      |> put_in([:s2s, :boot], boot)
      |> put_in([:s2s, :remote_admin],
        enabled: true,
        actions: [:rehash],
        origin_sids: ["root"],
        operator_roles: ["oper"]
      )

    {:ok, manager} =
      Manager.start_link(
        config: configured,
        rehash_fun: fn ->
          send(parent, :rehash_started)
          Process.sleep(150)
          :ok
        end
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    args = %{"action" => "rehash", "neighbor_sid" => nil, "reason" => "maintenance"}

    guards = %{
      "actor_uid" => nil,
      "actor_user_rev" => nil,
      "actor_join_id" => nil,
      "target_user_rev" => nil,
      "target_join_id" => nil,
      "channel" => nil,
      "policy_epoch" => nil,
      "policy_revision" => nil
    }

    spawn(fn ->
      send(parent, {:request_return, Manager.request(manager, "root", %{"user" => uid}, "admin", args, guards)})
    end)

    assert_receive :rehash_started, 1_000
    assert_receive {:request_return, {:ok, _request_id}}, 200
    assert Manager.status(manager).rehash_in_progress?
    assert eventually(fn -> not Manager.status(manager).rehash_in_progress? end, 40)
  end

  test "executes a request addressed to the local boot through the reply path" do
    test_pid = self()

    {:ok, manager} =
      Manager.start_link(
        config: config(),
        reply_fun: fn result -> send(test_pid, {:s2s_reply, result}) end
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    args = %{"command" => "VERSION", "params" => [], "target_uid" => nil, "view" => "client"}

    guards = %{
      "actor_uid" => nil,
      "actor_user_rev" => nil,
      "actor_join_id" => nil,
      "target_user_rev" => nil,
      "target_join_id" => nil,
      "channel" => nil,
      "policy_epoch" => nil,
      "policy_revision" => nil
    }

    assert {:ok, _request_id} =
             Manager.request(manager, "root", %{"server" => "root"}, "query", args, guards)

    assert_receive {:s2s_reply,
                    %{
                      status: "OK",
                      done: true,
                      payload: %{"items" => [%{"command" => "351", "source" => %{"server" => "root"}}]}
                    }}
  end

  test "correlates a private message rejection with its originating C2S process" do
    parent = self()
    boot = Identity.boot()
    actor_uid = Identity.uid()
    target_uid = Identity.uid()

    insert(:user, uid: actor_uid, pid: self(), nick: "Sender", home_sid: "root", home_boot: boot)
    insert(:user, uid: target_uid, pid: spawn(fn -> :ok end), nick: "Target", home_sid: "root", home_boot: boot)

    item = %{
      "command" => "477",
      "params" => ["Sender", "Target"],
      "trailing" => "You must be identified to message this user",
      "source" => %{"server" => "root"},
      "tags" => %{}
    }

    configured = put_in(config(), [:s2s, :boot], boot)

    {:ok, manager} =
      Manager.start_link(
        config: configured,
        delivery_fun: fn _runtime, frame ->
          send(parent, {:message_frame, frame})
          {:error, {:message_rejected, [item]}}
        end
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    assert :ok =
             Manager.publish_message(
               manager,
               actor_uid,
               %{"user" => target_uid},
               "PRIVMSG",
               "hello",
               %{},
               nil,
               reply_to: {self(), actor_uid, %{}}
             )

    assert_receive {:message_frame, %{"request_id" => request_id, "command" => "PRIVMSG"}}, 1_000

    assert_receive {
                     :s2s_reply,
                     ^actor_uid,
                     ^request_id,
                     %{status: "REJECTED", done: true, payload: %{"items" => [%{"command" => "477"}]}},
                     %{}
                   },
                   1_000

    assert Manager.status(manager).pending_messages == 0
  end

  test "expires a private message waiter with a terminal timeout" do
    parent = self()
    boot = Identity.boot()
    actor_uid = Identity.uid()
    target_uid = Identity.uid()
    insert(:user, uid: actor_uid, pid: self(), nick: "Sender", home_sid: "root", home_boot: boot)
    insert(:user, uid: target_uid, pid: spawn(fn -> :ok end), nick: "Target", home_sid: "root", home_boot: boot)

    {:ok, manager} = Manager.start_link(config: put_in(config(), [:s2s, :boot], boot))
    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    request_id = Identity.nonce()

    :sys.replace_state(manager, fn state ->
      waiter = %{pid: parent, uid: actor_uid, context: %{}, deadline: Requests.monotonic_ms() - 1}
      %{state | message_waiters: %{request_id => waiter}}
    end)

    send(manager, :s2s_request_expiry)

    assert_receive {
                     :s2s_reply,
                     ^actor_uid,
                     ^request_id,
                     %{status: "TIMEOUT", done: true, payload: %{"error" => %{"code" => "TIMEOUT"}}},
                     %{}
                   },
                   1_000

    assert Manager.status(manager).pending_messages == 0
  end

  test "cancels a private message waiter when its C2S recipient disappears" do
    parent = self()
    boot = Identity.boot()
    actor_uid = Identity.uid()
    target_uid = Identity.uid()
    insert(:user, uid: actor_uid, pid: self(), nick: "Sender", home_sid: "root", home_boot: boot)
    insert(:user, uid: target_uid, pid: spawn(fn -> :ok end), nick: "Target", home_sid: "root", home_boot: boot)

    {:ok, manager} = Manager.start_link(config: put_in(config(), [:s2s, :boot], boot))
    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    request_id = Identity.nonce()

    :sys.replace_state(manager, fn state ->
      waiter = %{pid: parent, uid: actor_uid, context: %{}, deadline: Requests.monotonic_ms() + 15_000}
      %{state | message_waiters: %{request_id => waiter}}
    end)

    assert :ok = Manager.cancel_recipient(manager, parent, actor_uid)

    assert_receive {
                     :s2s_reply,
                     ^actor_uid,
                     ^request_id,
                     %{status: "CANCELLED", done: true, payload: %{"error" => %{"code" => "CANCELLED"}}},
                     %{}
                   },
                   1_000

    assert Manager.status(manager).pending_messages == 0
  end

  test "queues routed messages until a synchronizing peer becomes active" do
    {manager, session, remote} = active_child()
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    actor_uid = Identity.uid()
    target_uid = Identity.uid()
    local = Manager.local_hello(manager)

    actor = %{
      "uid" => actor_uid,
      "home" => %{"sid" => "root", "boot" => local["boot"]},
      "rev" => 1,
      "effective_nick" => "Sender",
      "requested_nick" => "Sender"
    }

    target = %{
      "uid" => target_uid,
      "home" => %{"sid" => "leaf", "boot" => remote["boot"]},
      "rev" => 1,
      "effective_nick" => "Target",
      "requested_nick" => "Target"
    }

    :sys.replace_state(manager, fn state ->
      runtime = %{state.runtime | users: Map.merge(state.runtime.users, %{actor_uid => actor, target_uid => target})}
      session_record = %{state.sessions[session] | status: :syncing, outgoing_sync: %{sync_id: Identity.nonce()}}
      %{state | runtime: runtime, sessions: Map.put(state.sessions, session, session_record)}
    end)

    assert :ok =
             Manager.publish_message(
               manager,
               actor_uid,
               %{"user" => target_uid},
               "PRIVMSG",
               "queued until sync",
               %{},
               nil
             )

    state = :sys.get_state(manager)
    assert [%{"t" => "message", "text" => "queued until sync"}] = state.sessions[session].pending

    assert :ok = Manager.session_event(manager, session, :active)
    assert_receive {:frame, %{"t" => "message", "text" => "queued until sync"}}, 1_000
  end

  test "closes a synchronizing link when the aggregate pending queue is full" do
    {manager, session, remote} =
      active_child(put_in(config(), [:s2s, :budgets], max_pending_requests_origin: 128, aggregate_pending_frames: 1))

    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    actor_uid = Identity.uid()
    target_uid = Identity.uid()
    local = Manager.local_hello(manager)

    actor = %{
      "uid" => actor_uid,
      "home" => %{"sid" => "root", "boot" => local["boot"]},
      "rev" => 1,
      "effective_nick" => "Sender",
      "requested_nick" => "Sender"
    }

    target = %{
      "uid" => target_uid,
      "home" => %{"sid" => "leaf", "boot" => remote["boot"]},
      "rev" => 1,
      "effective_nick" => "Target",
      "requested_nick" => "Target"
    }

    :sys.replace_state(manager, fn state ->
      runtime = %{state.runtime | users: Map.merge(state.runtime.users, %{actor_uid => actor, target_uid => target})}
      session_record = %{state.sessions[session] | status: :syncing, outgoing_sync: %{sync_id: Identity.nonce()}}
      %{state | runtime: runtime, sessions: Map.put(state.sessions, session, session_record)}
    end)

    assert :ok = Manager.publish_message(manager, actor_uid, %{"user" => target_uid}, "PRIVMSG", "first", %{}, nil)
    assert Manager.status(manager).pending_link_frames == 1

    assert :ok = Manager.publish_message(manager, actor_uid, %{"user" => target_uid}, "PRIVMSG", "second", %{}, nil)
    assert_receive {:closed, "RESOURCE", "aggregate link output queue"}, 1_000
    assert eventually(fn -> Manager.status(manager).sessions == [] end)
    assert Manager.status(manager).pending_link_frames == 0
  end

  test "bounds the aggregate snapshot delta queue independently of link output" do
    {manager, session, remote} =
      active_child(put_in(config(), [:s2s, :budgets], aggregate_pending_frames: 1, aggregate_pending_bytes: 4_096))

    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    unknown_edge = String.duplicate("f", 64)
    row = %{"kind" => "topology.ready", "edge_id" => unknown_edge, "side" => "leaf"}
    frame = state_frame(remote, [row])

    send(manager, {:s2s_session_event, session, {:frame, frame, nil}})
    assert eventually(fn -> Manager.status(manager).pending_sync_frames == 1 end)
    assert Manager.status(manager).pending_sync_bytes > 0
    assert Manager.status(manager).pending_link_frames == 0

    send(manager, {:s2s_session_event, session, {:frame, frame, nil}})
    assert_receive {:closed, "RESOURCE", "aggregate snapshot delta queue"}, 1_000
    assert eventually(fn -> Manager.status(manager).sessions == [] end)
    assert Manager.status(manager).pending_sync_frames == 0
    assert Manager.status(manager).pending_sync_bytes == 0
  end

  test "returns a terminal resource reply when incoming request capacity is exhausted" do
    {manager, session, remote} = active_child()
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    local = Manager.local_hello(manager)
    origin = %{"sid" => "leaf", "boot" => remote["boot"]}
    target = %{"sid" => "root", "boot" => local["boot"]}

    build_request = fn request_id ->
      Requests.build(
        origin,
        target,
        request_id,
        %{"server" => "leaf"},
        "query",
        %{"command" => "VERSION", "params" => [], "target_uid" => nil, "view" => "client"},
        guards(),
        5_000,
        1
      )
    end

    {:ok, first} = build_request.(Identity.nonce())
    {:ok, second} = build_request.(Identity.nonce())
    {:ok, requests, _pending} = Requests.admit(Requests.new(max_pending: 1), first)

    :sys.replace_state(manager, fn state -> %{state | requests: requests} end)
    send(manager, {:s2s_session_event, session, {:frame, second, nil}})

    assert_receive {:frame, %{"t" => "reply", "request_id" => request_id, "status" => "RESOURCE"}}, 1_000
    assert request_id == second["request_id"]
    assert Manager.status(manager).pending_requests == 1
  end

  test "silently cancels only the in-flight SASL request for the matching attempt" do
    parent = self()
    uid = Identity.uid()
    attempt_id = Identity.nonce()
    request_id = Identity.nonce()

    {:ok, manager} = Manager.start_link(config: put_in(config(), [:s2s, :boot], Identity.boot()))
    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    :sys.replace_state(manager, fn state ->
      frame = %{
        "request_id" => request_id,
        "origin" => %{"sid" => state.runtime.sid, "boot" => state.runtime.boot},
        "method" => "sasl",
        "args" => %{"uid" => uid, "attempt_id" => attempt_id, "phase" => "step"}
      }

      key = {state.runtime.sid, state.runtime.boot, request_id}

      pending = %{
        key => %{
          frame: frame,
          fingerprint: "fingerprint",
          received_at: Requests.monotonic_ms(),
          deadline: Requests.monotonic_ms() + 15_000,
          next_part: 0
        }
      }

      waiter = %{pid: parent, uid: uid, context: %{sasl: :native_s2s_sasl}}
      requests = %{state.requests | pending: pending}

      %{state | requests: requests, request_waiters: %{request_id => waiter}}
    end)

    assert :ok = Manager.cancel_sasl_attempt(manager, parent, uid, attempt_id)
    assert eventually(fn -> Manager.status(manager).pending_requests == 0 end)
    refute_received {:s2s_reply, ^uid, ^request_id, _, _}
  end

  test "cancels a routed request when its next hop disappears" do
    parent = self()
    {:ok, manager} = Manager.start_link(config: config())
    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    peer_info = %{address: {192, 0, 2, 12}, port: 7000, certfp: String.duplicate("a", 64)}
    assert {:ok, _peer} = Manager.admit_peer(manager, :incoming, peer_info)
    local_hello = Manager.local_hello(manager)

    {:ok, session} = FakeSession.start_link(parent)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    generation = Identity.nonce()

    assert {:ok, ^generation} =
             Manager.register_session(manager, session, %{
               direction: :incoming,
               peer_sid: "leaf",
               peer_name: "leaf.example.test",
               peer_info: peer_info,
               owner: session,
               generation: generation,
               local_hello: local_hello
             })

    remote_config =
      config()
      |> put_in([:s2s, :server_id], "leaf")
      |> put_in([:s2s, :server_name], "leaf.example.test")

    remote = Profile.hello(remote_config, Identity.boot(), Identity.nonce())
    assert :ok = Manager.admit_hello(manager, session, remote)

    local = local_hello
    assert {:ok, edge_id} = Identity.edge_id(local, remote)

    topology = %{
      "kind" => "topology.add",
      "nodes" => [
        %{"sid" => "root", "boot" => local["boot"], "name" => local["name"], "description" => ""},
        %{"sid" => "leaf", "boot" => remote["boot"], "name" => remote["name"], "description" => ""}
      ],
      "edges" => [
        %{
          "id" => edge_id,
          "a" => %{"sid" => "leaf", "boot" => remote["boot"]},
          "b" => %{"sid" => "root", "boot" => local["boot"]},
          "ready_sides" => ["leaf", "root"]
        }
      ]
    }

    assert {:ok, snapshot} = Sync.capture(Identity.nonce(), 1, %{topology: [topology]})
    assert {:ok, %{frames: frames}} = Sync.frames(snapshot)

    Enum.each(frames, fn frame ->
      body = if frame["phase"] == "rows", do: JSON.encode(frame), else: nil
      send(manager, {:s2s_session_event, session, {:frame, frame, body}})
    end)

    assert :ok = Manager.session_event(manager, session, :active)

    assert eventually(fn -> Manager.status(manager).reachable_sids == ["leaf", "root"] end)

    uid = Identity.uid()

    guards = %{
      "actor_uid" => nil,
      "actor_user_rev" => nil,
      "actor_join_id" => nil,
      "target_user_rev" => nil,
      "target_join_id" => nil,
      "channel" => nil,
      "policy_epoch" => nil,
      "policy_revision" => nil
    }

    assert {:ok, request_id} =
             Manager.request_with_reply(
               manager,
               "leaf",
               %{"server" => "root"},
               "query",
               %{"command" => "VERSION", "params" => [], "target_uid" => nil, "view" => "client"},
               guards,
               self(),
               uid
             )

    assert_receive {:frame, %{"t" => "request", "request_id" => ^request_id}}
    assert :ok = Manager.link_closed(manager, session, :transport)

    assert_receive {
                     :s2s_reply,
                     ^uid,
                     ^request_id,
                     %{status: "CANCELLED", done: true},
                     %{}
                   },
                   1_000

    assert Manager.status(manager).pending_requests == 0
  end

  test "reports an uncertain outcome when a routed mutating request loses its next hop" do
    parent = self()
    {manager, session, _remote} = active_child()
    on_exit(fn -> stop_if_alive(manager) end)
    on_exit(fn -> stop_if_alive(session) end)

    uid = Identity.uid()

    assert {:ok, request_id} =
             Manager.request_with_reply_context(
               manager,
               "leaf",
               %{"server" => "root"},
               "service",
               %{
                 "service" => "NickServ",
                 "arguments" => ["REGISTER", "password"],
                 "scope" => "global",
                 "channel" => nil
               },
               guards(),
               parent,
               uid,
               %{}
             )

    assert_receive {:frame, %{"t" => "request", "request_id" => ^request_id}}, 1_000
    assert :ok = Manager.link_closed(manager, session, :transport)

    assert_receive {
                     :s2s_reply,
                     ^uid,
                     ^request_id,
                     %{status: "UNKNOWN_OUTCOME", done: true, payload: %{"error" => %{"code" => "UNKNOWN_OUTCOME"}}},
                     %{}
                   },
                   1_000

    assert Manager.status(manager).pending_requests == 0
  end

  test "cancels a read-only service request when its next hop disappears" do
    parent = self()
    {manager, session, _remote} = active_child()
    on_exit(fn -> stop_if_alive(manager) end)
    on_exit(fn -> stop_if_alive(session) end)

    uid = Identity.uid()

    assert {:ok, request_id} =
             Manager.request_with_reply_context(
               manager,
               "leaf",
               %{"server" => "root"},
               "service",
               %{"service" => "NickServ", "arguments" => ["INFO", "Alice"], "scope" => "global", "channel" => nil},
               guards(),
               parent,
               uid,
               %{}
             )

    assert_receive {:frame, %{"t" => "request", "request_id" => ^request_id}}, 1_000
    assert :ok = Manager.link_closed(manager, session, :transport)

    assert_receive {
                     :s2s_reply,
                     ^uid,
                     ^request_id,
                     %{status: "CANCELLED", done: true},
                     %{}
                   },
                   1_000

    assert Manager.status(manager).pending_requests == 0
  end

  test "coalesces a missing-channel repair and replays the deferred state" do
    {manager, session, remote} = active_child()
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    channel = %{"name" => "#repair", "born_ms" => 1, "cid" => Identity.cid()}
    first = channel_field(channel, remote, 1, "first")
    second = channel_field(channel, remote, 2, "second")

    send(manager, {:s2s_session_event, session, {:frame, state_frame(remote, [first]), nil}})

    assert_receive {:frame, %{"t" => "request", "method" => "snapshot"} = request}, 1_000
    assert request["args"] == %{"scope" => "channel", "channel" => "#repair", "for_uid" => nil}

    send(manager, {:s2s_session_event, session, {:frame, state_frame(remote, [second]), nil}})
    refute_receive {:frame, %{"t" => "request", "method" => "snapshot"}}, 100

    begin = %{"phase" => "begin", "scope" => "channel", "channel" => "#repair"}
    rows = %{"phase" => "rows", "rows" => [%{"kind" => "channel.ensure", "channel" => channel}, second]}
    ending = %{"phase" => "end", "scope" => "channel", "rows" => 2, "exists" => true}

    for {part, index, done} <- [{begin, 0, false}, {rows, 1, false}, {ending, 2, true}] do
      assert {:ok, reply} = Requests.build_reply_from_request(request, "OK", part, index, done, 1)
      send(manager, {:s2s_session_event, session, {:frame, reply, nil}})
    end

    assert eventually(fn -> Manager.status(manager).pending_repairs == 0 end)
    assert Manager.runtime_view(manager).channels["#repair"].registers["topic"].value["text"] == "second"
  end

  test "holds a merge repair until the owner edge becomes ready" do
    {manager, session, remote} = active_child(config(), activate: false, ready_sides: ["leaf"])
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    assert Manager.status(manager).reachable_sids == ["root"]

    merge_id = Identity.nonce()

    begin = %{
      "kind" => "merge.begin",
      "id" => merge_id,
      "via" => %{"sid" => "leaf", "boot" => remote["boot"]}
    }

    channel = %{"name" => "#merge-repair", "born_ms" => 1, "cid" => Identity.cid()}
    field = channel_field(channel, remote, 1, "during merge")

    send(manager, {:s2s_session_event, session, {:frame, state_frame(remote, [begin]), nil}})

    merge_state = %{
      "t" => "state",
      "n" => 1,
      "origin" => %{"sid" => "leaf", "boot" => remote["boot"]},
      "actor" => %{"server" => "leaf"},
      "context" => %{"kind" => "merge", "id" => merge_id},
      "changes" => [field]
    }

    send(manager, {:s2s_session_event, session, {:frame, merge_state, nil}})
    assert eventually(fn -> Manager.status(manager).pending_repairs == 1 end)
    refute_receive {:frame, %{"t" => "request", "method" => "snapshot"}}, 100

    finish = %{"kind" => "merge.end", "id" => merge_id}
    send(manager, {:s2s_session_event, session, {:frame, state_frame(remote, [finish]), nil}})
    assert eventually(fn -> MapSet.equal?(Manager.runtime_view(manager).merge_contexts, MapSet.new()) end)
    assert Manager.status(manager).pending_repairs == 1
    refute_receive {:frame, %{"t" => "request", "method" => "snapshot"}}, 100

    assert :ok = Manager.session_event(manager, session, :active)
    assert_receive {:frame, %{"t" => "request", "method" => "snapshot", "args" => %{"scope" => "channel"}}}, 1_000
  end

  test "shares the repair limit between policy and channel repairs" do
    limited_config =
      config()
      |> put_in([:s2s, :services_authority], "leaf")
      |> put_in([:s2s, :budgets, :max_repairs], 1)

    {manager, session, remote} = active_child(limited_config)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    epoch = Manager.runtime_view(manager).policy.epoch

    invalidation = %{
      "kind" => "policy.change",
      "epoch" => epoch,
      "revision" => 1,
      "changes" => nil
    }

    send(manager, {:s2s_session_event, session, {:frame, state_frame(remote, [invalidation]), nil}})
    assert_receive {:frame, %{"t" => "request", "method" => "snapshot", "args" => %{"scope" => "policy"}}}, 1_000
    assert Manager.status(manager).pending_policy_repairs == 1

    channel = %{"name" => "#repair-limit", "born_ms" => 1, "cid" => Identity.cid()}
    field = channel_field(channel, remote, 1, "blocked")
    send(manager, {:s2s_session_event, session, {:frame, state_frame(remote, [field]), nil}})

    assert eventually(fn -> Manager.status(manager).sessions == [] end)
    assert Manager.status(manager).pending_repairs == 0
  end

  test "closes the responsible link on an invalid channel repair row" do
    {manager, session, remote} = active_child()
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    channel = %{"name" => "#repair-invalid", "born_ms" => 1, "cid" => Identity.cid()}
    field = channel_field(channel, remote, 1, "topic")
    send(manager, {:s2s_session_event, session, {:frame, state_frame(remote, [field]), nil}})
    assert_receive {:frame, %{"t" => "request"} = request}, 1_000

    begin = %{"phase" => "begin", "scope" => "channel", "channel" => "#repair-invalid"}
    policy = %{"kind" => "policy.change", "epoch" => Identity.nonce(), "revision" => 1, "changes" => []}
    rows = %{"phase" => "rows", "rows" => [policy]}

    assert {:ok, reply} = Requests.build_reply_from_request(request, "OK", begin, 0, false, 1)
    send(manager, {:s2s_session_event, session, {:frame, reply, nil}})
    assert {:ok, reply} = Requests.build_reply_from_request(request, "OK", rows, 1, false, 1)
    send(manager, {:s2s_session_event, session, {:frame, reply, nil}})

    assert eventually(fn -> Manager.status(manager).sessions == [] end)
    assert Manager.status(manager).pending_repairs == 0
    assert Manager.runtime_view(manager).policy.revision == 0
  end

  test "rejects a channel repair for a different incarnation" do
    {manager, session, remote} = active_child()
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    channel = %{"name" => "#repair-incarnation", "born_ms" => 1, "cid" => Identity.cid()}
    field = channel_field(channel, remote, 1, "topic")
    send(manager, {:s2s_session_event, session, {:frame, state_frame(remote, [field]), nil}})
    assert_receive {:frame, %{"t" => "request"} = request}, 1_000

    begin = %{"phase" => "begin", "scope" => "channel", "channel" => "#repair-incarnation"}
    wrong_channel = %{channel | "cid" => Identity.cid()}
    rows = %{"phase" => "rows", "rows" => [%{"kind" => "channel.ensure", "channel" => wrong_channel}]}

    assert {:ok, reply} = Requests.build_reply_from_request(request, "OK", begin, 0, false, 1)
    send(manager, {:s2s_session_event, session, {:frame, reply, nil}})
    assert {:ok, reply} = Requests.build_reply_from_request(request, "OK", rows, 1, false, 1)
    send(manager, {:s2s_session_event, session, {:frame, reply, nil}})

    assert eventually(fn -> Manager.status(manager).sessions == [] end)
    refute Map.has_key?(Manager.runtime_view(manager).channels, "#repair-incarnation")
  end

  test "repairs a policy revision gap from the authority and replays the queued delta" do
    authority_config = put_in(config(), [:s2s, :services_authority], "leaf")
    {manager, session, remote} = active_child(authority_config)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    runtime = Manager.runtime_view(manager)
    epoch = runtime.policy.epoch

    change = %{
      "kind" => "policy.change",
      "epoch" => epoch,
      "revision" => 3,
      "changes" => []
    }

    send(manager, {:s2s_session_event, session, {:frame, state_frame(remote, [change]), nil}})

    assert_receive {:frame, %{"t" => "request", "method" => "snapshot"} = request}, 1_000
    assert request["args"] == %{"scope" => "policy", "channel" => nil, "for_uid" => nil}
    assert Manager.status(manager).policy_ready? == false

    begin = %{"snapshot" => "policy", "phase" => "begin", "epoch" => epoch, "revision" => 2, "objects" => 0}
    ending = %{"snapshot" => "policy", "phase" => "end", "epoch" => epoch, "revision" => 2, "objects" => 0}

    for {part, index, done} <- [{begin, 0, false}, {ending, 1, true}] do
      assert {:ok, reply} = Requests.build_reply_from_request(request, "OK", part, index, done, 1)
      send(manager, {:s2s_session_event, session, {:frame, reply, nil}})
    end

    assert eventually(fn -> Manager.status(manager).pending_policy_repairs == 0 end)
    status = Manager.status(manager)
    assert status.policy_ready? == true
    assert status.policy_revision == 3
  end

  test "holds policy deltas behind an invalidation until the complete image is installed" do
    authority_config = put_in(config(), [:s2s, :services_authority], "leaf")
    {manager, session, remote} = active_child(authority_config)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    epoch = Manager.runtime_view(manager).policy.epoch

    invalidation = %{
      "kind" => "policy.change",
      "epoch" => epoch,
      "revision" => 1,
      "changes" => nil
    }

    queued = %{
      "kind" => "policy.change",
      "epoch" => epoch,
      "revision" => 2,
      "changes" => []
    }

    send(manager, {:s2s_session_event, session, {:frame, state_frame(remote, [invalidation]), nil}})
    assert_receive {:frame, %{"t" => "request", "method" => "snapshot"} = request}, 1_000

    send(manager, {:s2s_session_event, session, {:frame, state_frame(remote, [queued]), nil}})
    refute_receive {:frame, %{"t" => "request", "method" => "snapshot"}}, 100

    begin = %{"snapshot" => "policy", "phase" => "begin", "epoch" => epoch, "revision" => 1, "objects" => 0}
    ending = %{"snapshot" => "policy", "phase" => "end", "epoch" => epoch, "revision" => 1, "objects" => 0}

    for {part, index, done} <- [{begin, 0, false}, {ending, 1, true}] do
      assert {:ok, reply} = Requests.build_reply_from_request(request, "OK", part, index, done, 1)
      send(manager, {:s2s_session_event, session, {:frame, reply, nil}})
    end

    assert eventually(fn -> Manager.status(manager).pending_policy_repairs == 0 end)
    status = Manager.status(manager)
    assert status.policy_ready? == true
    assert status.policy_revision == 2
  end

  test "fences a request whose origin is not on the authenticated ingress route" do
    {manager, session, _remote} = active_child()
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)
    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    local = Manager.local_hello(manager)

    assert {:ok, frame} =
             Requests.build(
               %{"sid" => "root", "boot" => local["boot"]},
               %{"sid" => "root", "boot" => local["boot"]},
               Identity.nonce(),
               %{"server" => "root"},
               "query",
               %{"command" => "VERSION", "params" => [], "target_uid" => nil, "view" => "client"},
               %{
                 "actor_uid" => nil,
                 "actor_user_rev" => nil,
                 "actor_join_id" => nil,
                 "target_user_rev" => nil,
                 "target_join_id" => nil,
                 "channel" => nil,
                 "policy_epoch" => nil,
                 "policy_revision" => nil
               },
               1_000,
               1
             )

    send(manager, {:s2s_session_event, session, {:frame, frame, nil}})
    assert eventually(fn -> Manager.status(manager).sessions == [] end)
  end

  test "returns a transit timeout without executing an expired request" do
    {manager, session, remote} = active_child()
    on_exit(fn -> stop_if_alive(manager) end)
    on_exit(fn -> stop_if_alive(session) end)

    assert {:ok, frame} =
             Requests.build(
               %{"sid" => "leaf", "boot" => remote["boot"]},
               Manager.local_hello(manager) |> Map.take(["sid", "boot"]),
               Identity.nonce(),
               %{"server" => "leaf"},
               "query",
               %{"command" => "VERSION", "params" => [], "target_uid" => nil, "view" => "client"},
               guards(),
               1_000,
               1
             )

    send(
      manager,
      {:s2s_session_event, session, {:frame, frame, nil, Requests.monotonic_ms() - 2_000}}
    )

    assert_receive {:frame, %{"t" => "reply", "status" => "TIMEOUT", "request_id" => request_id}}
    assert request_id == frame["request_id"]
    assert Manager.status(manager).pending_requests == 0
  end

  defp active_child(config \\ config(), options \\ []) do
    parent = self()
    {:ok, manager} = Manager.start_link(config: config)
    Process.unlink(manager)

    peer_info = %{address: {192, 0, 2, 21}, port: 7000, certfp: String.duplicate("a", 64)}
    assert {:ok, _peer} = Manager.admit_peer(manager, :incoming, peer_info)
    local = Manager.local_hello(manager)
    {:ok, session} = FakeSession.start_link(parent)

    generation = Identity.nonce()

    assert {:ok, ^generation} =
             Manager.register_session(manager, session, %{
               direction: :incoming,
               peer_sid: "leaf",
               peer_name: "leaf.example.test",
               peer_info: peer_info,
               owner: session,
               generation: generation,
               local_hello: local
             })

    remote_config =
      config
      |> put_in([:s2s, :server_id], "leaf")
      |> put_in([:s2s, :server_name], "leaf.example.test")

    remote = Profile.hello(remote_config, Identity.boot(), Identity.nonce())
    assert :ok = Manager.admit_hello(manager, session, remote)
    assert {:ok, edge_id} = Identity.edge_id(local, remote)

    topology = %{
      "kind" => "topology.add",
      "nodes" => [
        %{"sid" => "root", "boot" => local["boot"], "name" => local["name"], "description" => ""},
        %{"sid" => "leaf", "boot" => remote["boot"], "name" => remote["name"], "description" => ""}
      ],
      "edges" => [
        %{
          "id" => edge_id,
          "a" => %{"sid" => "leaf", "boot" => remote["boot"]},
          "b" => %{"sid" => "root", "boot" => local["boot"]},
          "ready_sides" => Keyword.get(options, :ready_sides, ["leaf", "root"])
        }
      ]
    }

    assert {:ok, snapshot} = Sync.capture(Identity.nonce(), 1, %{topology: [topology]})
    assert {:ok, %{frames: frames}} = Sync.frames(snapshot)

    Enum.each(frames, fn frame ->
      body = if frame["phase"] == "rows", do: JSON.encode(frame), else: nil
      send(manager, {:s2s_session_event, session, {:frame, frame, body}})
    end)

    if Keyword.get(options, :activate, true) do
      assert :ok = Manager.session_event(manager, session, :active)
      assert eventually(fn -> Manager.status(manager).reachable_sids == ["leaf", "root"] end)
    end

    {manager, session, remote}
  end

  defp channel_field(channel, remote, stamp, text) do
    %{
      "kind" => "channel.field",
      "channel" => channel,
      "field" => "topic",
      "value" => %{"text" => text, "setter" => "leaf", "set_ms" => stamp},
      "stamp" => [stamp, "leaf", remote["boot"]],
      "setter" => %{"server" => "leaf"}
    }
  end

  defp state_frame(remote, changes) do
    %{
      "t" => "state",
      "n" => 1,
      "origin" => %{"sid" => "leaf", "boot" => remote["boot"]},
      "actor" => %{"server" => "leaf"},
      "context" => %{"kind" => "live"},
      "changes" => changes
    }
  end

  defp guards do
    %{
      "actor_uid" => nil,
      "actor_user_rev" => nil,
      "actor_join_id" => nil,
      "target_user_rev" => nil,
      "target_join_id" => nil,
      "channel" => nil,
      "policy_epoch" => nil,
      "policy_revision" => nil
    }
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp stop_if_alive(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
