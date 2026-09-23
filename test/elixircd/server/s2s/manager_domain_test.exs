defmodule ElixIRCd.Server.S2S.ManagerDomainTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Manager
  alias ElixIRCd.Server.S2S.Output
  alias ElixIRCd.Server.S2S.Policy
  alias ElixIRCd.Server.S2S.PolicyStore

  defp config(boot) do
    [
      s2s: [
        enabled: true,
        network_id: "manager-domain-test",
        semantic_revision: 1,
        server_id: "root",
        server_name: "root.example.test",
        services_authority: nil,
        boot: boot,
        roster: [[sid: "root", name: "root.example.test", parent: nil]],
        children: %{},
        parent_connection: nil,
        timeouts: [heartbeat_ms: 60_000, heartbeat_timeout_ms: 60_000],
        budgets: [max_pending_requests_origin: 128]
      ],
      settings: [case_mapping: :ascii, utf8_only: true]
    ]
  end

  defp guards(user, channel, join_id) do
    %{
      "actor_uid" => user.uid,
      "actor_user_rev" => nil,
      "actor_join_id" => nil,
      "target_user_rev" => user.owner_rev,
      "target_join_id" => join_id,
      "channel" => %{"name" => channel.name, "born_ms" => channel.born_ms, "cid" => channel.cid},
      "policy_epoch" => nil,
      "policy_revision" => nil
    }
  end

  test "executes a local owner mutation through Manager.request and drains both effects" do
    parent = self()

    receiver =
      spawn(fn ->
        receive do
          message -> send(parent, {:c2s, message})
        end
      end)

    on_exit(fn -> if Process.alive?(receiver), do: Process.exit(receiver, :kill) end)

    boot = Identity.boot()

    user =
      insert(:user,
        pid: receiver,
        home_sid: "root",
        home_boot: boot,
        owner_rev: 1,
        membership_rev: 1
      )

    channel = insert(:channel, name: "#manager-part", born_ms: 21, cid: Identity.cid())
    membership = insert(:user_channel, user: user, channel: channel, join_id: 9)

    {:ok, manager} =
      Manager.start_link(
        config: config(boot),
        reply_fun: fn result -> send(parent, {:s2s_reply, result}) end
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    args = %{
      "action" => "part",
      "target_uid" => user.uid,
      "value" => %{
        "channel" => %{"name" => channel.name, "born_ms" => channel.born_ms, "cid" => channel.cid},
        "join_id" => membership.join_id
      },
      "reason" => "manager owner test"
    }

    assert {:ok, _request_id} =
             Manager.request(
               manager,
               "root",
               %{"user" => user.uid},
               "user_action",
               args,
               guards(user, channel, membership.join_id)
             )

    assert_receive {:s2s_reply, %{status: "OK", done: true, payload: %{"result" => %{"accepted" => true}}}}
    assert_receive {:c2s, {:broadcast, line}}
    assert line =~ " PART #manager-part"
    assert line =~ "manager owner test"

    assert {:error, :user_channel_not_found} =
             Memento.transaction!(fn -> UserChannels.get_by_user_pid_and_channel_name(receiver, channel.name) end)
  end

  test "runs the SASL verification step outside the manager and returns a policy binding" do
    account_id = Identity.uid()
    registered_nick = insert(:registered_nick, nickname: "Alice", account_id: account_id)
    boot = Identity.boot()
    parent = self()

    {:ok, manager} =
      Manager.start_link(
        config: put_in(config(boot), [:s2s, :services_authority], "root"),
        sasl_options: [plain_lookup: fn "alice", "secret", _client_info -> {:ok, account_id} end],
        reply_fun: fn result -> send(parent, {:sasl_reply, result}) end
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    uid = Identity.uid()
    attempt_id = Identity.nonce()

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

    client_info = %{
      "secure_client" => true,
      "realhost" => "client.example.test",
      "address" => "192.0.2.10",
      "client_certfp" => nil
    }

    start_args = %{
      "uid" => uid,
      "attempt_id" => attempt_id,
      "step" => 0,
      "phase" => "start",
      "mechanism" => "PLAIN",
      "data" => nil,
      "client_info" => client_info
    }

    assert {:ok, _start_request} =
             Manager.request(manager, "root", %{"server" => "root"}, "sasl", start_args, guards)

    assert_receive {:sasl_reply, %{status: "OK", payload: %{"sasl" => "continue"}}}

    step_args = %{start_args | "step" => 1, "phase" => "step", "data" => Base.encode64(<<0, "alice", 0, "secret">>)}

    assert {:ok, _step_request} =
             Manager.request(manager, "root", %{"server" => "root"}, "sasl", step_args, guards)

    assert_receive {:sasl_reply, %{status: "OK", payload: %{"sasl" => "success", "binding" => binding}}},
                   1_000

    assert binding["account_id"] == registered_nick.account_id
    assert Identity.valid_id?(binding["policy_epoch"])
  end

  test "times out a slow SASL worker and releases its request and attempt" do
    parent = self()
    boot = Identity.boot()
    uid = Identity.uid()
    attempt_id = Identity.nonce()

    {:ok, manager} =
      Manager.start_link(
        config:
          config(boot)
          |> put_in([:s2s, :services_authority], "root")
          |> put_in([:s2s, :timeouts, :request_ms], 50),
        sasl_options: [
          plain_lookup: fn _username, _password, _client_info ->
            Process.sleep(250)
            {:ok, Identity.uid()}
          end
        ],
        reply_fun: fn result -> send(parent, {:sasl_timeout_reply, result}) end
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

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

    client_info = %{
      "secure_client" => true,
      "realhost" => "client.example.test",
      "address" => "192.0.2.10",
      "client_certfp" => nil
    }

    start_args = %{
      "uid" => uid,
      "attempt_id" => attempt_id,
      "step" => 0,
      "phase" => "start",
      "mechanism" => "PLAIN",
      "data" => nil,
      "client_info" => client_info
    }

    assert {:ok, _start_request} =
             Manager.request(manager, "root", %{"server" => "root"}, "sasl", start_args, guards)

    assert_receive {:sasl_timeout_reply, %{status: "OK", payload: %{"sasl" => "continue"}}}, 1_000

    step_args = %{
      start_args
      | "step" => 1,
        "phase" => "step",
        "data" => Base.encode64(<<0, "alice", 0, "secret">>)
    }

    assert {:ok, _step_request} =
             Manager.request(manager, "root", %{"server" => "root"}, "sasl", step_args, guards)

    assert_receive {:sasl_timeout_reply, %{status: "TIMEOUT", payload: %{"error" => error}}}, 3_000
    assert error["code"] == "TIMEOUT"
    assert eventually(fn -> Manager.status(manager).pending_sasl_attempts == 0 end, 300)
    assert Manager.status(manager).pending_sasl_jobs == 0
    assert Manager.status(manager).pending_requests == 0
  end

  test "executes account binding and operator changes for the local owner" do
    parent = self()
    boot = Identity.boot()
    policy_epoch = Identity.nonce()
    account_id = Identity.uid()
    registered_nick = insert(:registered_nick, nickname: "Alice", account_id: account_id)

    receiver =
      spawn(fn ->
        loop = fn loop ->
          receive do
            message ->
              send(parent, {:c2s, message})
              loop.(loop)
          end
        end

        loop.(loop)
      end)

    on_exit(fn -> if Process.alive?(receiver), do: Process.exit(receiver, :kill) end)

    user =
      insert(:user,
        pid: receiver,
        home_sid: "root",
        home_boot: boot,
        owner_rev: 1,
        registered: true,
        modes: []
      )

    config =
      config(boot)
      |> put_in([:s2s, :services_authority], "root")
      |> put_in([:s2s, :policy_epoch], policy_epoch)

    {:ok, manager} =
      Manager.start_link(
        config: config,
        reply_fun: fn result -> send(parent, {:account_oper_reply, result}) end
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    guards = %{
      "actor_uid" => user.uid,
      "actor_user_rev" => 1,
      "actor_join_id" => nil,
      "target_user_rev" => 1,
      "target_join_id" => nil,
      "channel" => nil,
      "policy_epoch" => policy_epoch,
      "policy_revision" => 1
    }

    account_args = %{
      "action" => "account",
      "target_uid" => user.uid,
      "value" => %{
        "binding" => %{
          "account_id" => account_id,
          "auth_epoch" => registered_nick.auth_epoch,
          "policy_epoch" => policy_epoch
        },
        "response_request_id" => nil
      },
      "reason" => "remote SASL"
    }

    assert {:ok, _account_request} =
             Manager.request(
               manager,
               "root",
               %{"service" => "NickServ"},
               "user_action",
               account_args,
               %{guards | "actor_uid" => nil, "actor_user_rev" => nil}
             )

    assert_receive {:account_oper_reply, %{status: "OK", done: true, payload: %{"result" => %{"accepted" => true}}}}
    assert_receive {:c2s, {:broadcast, account_notice}}
    assert account_notice =~ " 900 "
    assert_receive {:c2s, {:broadcast, sasl_notice}}
    assert sasl_notice =~ " 903 "

    {:ok, accounted_user} = Memento.transaction!(fn -> Users.get_by_uid(user.uid) end)
    assert accounted_user.identified_as == "Alice"
    assert accounted_user.sasl_authenticated == true
    assert accounted_user.owner_rev == 2

    oper_args = %{
      "action" => "oper",
      "target_uid" => user.uid,
      "value" => %{"enabled" => true, "role" => "oper"},
      "reason" => "operator grant"
    }

    assert {:ok, _oper_request} =
             Manager.request(
               manager,
               "root",
               %{"server" => "root"},
               "user_action",
               oper_args,
               %{guards | "actor_uid" => nil, "actor_user_rev" => nil, "target_user_rev" => 2}
             )

    assert_receive {:account_oper_reply, %{status: "OK", done: true, payload: %{"result" => %{"accepted" => true}}}}
    assert_receive {:c2s, {:broadcast, oper_notice}}
    assert oper_notice =~ " 381 "
    assert_receive {:c2s, {:broadcast, mode_notice}}
    assert mode_notice =~ " MODE "
    assert mode_notice =~ " +o"

    {:ok, operated_user} = Memento.transaction!(fn -> Users.get_by_uid(user.uid) end)
    assert :o in operated_user.modes
    assert operated_user.owner_rev == 3

    logout_args = %{
      "action" => "account",
      "target_uid" => user.uid,
      "value" => %{"binding" => nil, "response_request_id" => nil},
      "reason" => "logout"
    }

    assert {:ok, _logout_request} =
             Manager.request(
               manager,
               "root",
               %{"user" => user.uid},
               "user_action",
               logout_args,
               %{guards | "target_user_rev" => 3}
             )

    assert_receive {:account_oper_reply, %{status: "OK", done: true, payload: %{"result" => %{"accepted" => true}}}}
    assert_receive {:c2s, {:broadcast, logout_mode}}
    assert logout_mode =~ " MODE "
    assert logout_mode =~ " -r"
    assert_receive {:c2s, {:broadcast, logout_notice}}
    assert logout_notice =~ " 901 "

    {:ok, logged_out_user} = Memento.transaction!(fn -> Users.get_by_uid(user.uid) end)
    assert logged_out_user.identified_as == nil
    assert logged_out_user.sasl_authenticated == false
    assert logged_out_user.owner_rev == 4
  end

  test "completes a remote service IDENTIFY through the owner action" do
    parent = self()
    boot = Identity.boot()
    password = "identify-secret"
    account = insert(:registered_nick, nickname: "RemoteAlice", password: password)

    receiver =
      spawn(fn ->
        loop = fn loop ->
          receive do
            message ->
              send(parent, {:identify_c2s, message})
              loop.(loop)
          end
        end

        loop.(loop)
      end)

    on_exit(fn -> if Process.alive?(receiver), do: Process.exit(receiver, :kill) end)

    user =
      insert(:user,
        pid: receiver,
        nick: "RemoteAlice",
        home_sid: "root",
        home_boot: boot,
        owner_rev: 1,
        registered: true,
        transport: :tls,
        modes: [],
        capabilities: ["account-notify"]
      )

    config = put_in(config(boot), [:s2s, :services_authority], "root")

    {:ok, manager} =
      Manager.start_link(
        config: config,
        reply_fun: fn result -> send(parent, {:identify_reply, result}) end
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    args = %{
      "service" => "NickServ",
      "arguments" => ["IDENTIFY", password],
      "scope" => "global",
      "channel" => nil
    }

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

    assert {:ok, _request_id} = Manager.request(manager, "root", %{"user" => user.uid}, "service", args, guards)

    assert_receive {:identify_c2s, {:broadcast, registered_mode}}, 2_000
    assert registered_mode =~ " MODE "
    assert registered_mode =~ " +r"
    assert_receive {:identify_c2s, {:broadcast, account_notice}}, 2_000
    assert account_notice =~ " 900 "
    assert_receive {:identify_c2s, {:broadcast, sasl_success}}, 2_000
    assert sasl_success =~ " 903 "
    assert_receive {:identify_c2s, {:broadcast, account_change}}, 2_000
    assert account_change =~ " ACCOUNT "
    assert_receive {:identify_reply, %{status: "OK", done: true, payload: %{"items" => []}}}, 2_000

    assert {:ok, updated} = Memento.transaction!(fn -> Users.get_by_uid(user.uid) end)
    assert updated.identified_as == account.account_name
    assert :r in updated.modes
  end

  test "publishes the policy revision produced by an authority-local service mutation" do
    parent = self()
    boot = Identity.boot()

    user =
      insert(:user,
        nick: "PolicyRegistration",
        home_sid: "root",
        home_boot: boot,
        registered: true,
        created_at: DateTime.add(DateTime.utc_now(), -3_600, :second)
      )

    {:ok, manager} =
      Manager.start_link(
        config:
          config(boot)
          |> put_in([:s2s, :services_authority], "root")
          |> put_in([:s2s, :policy_epoch], Identity.nonce()),
        reply_fun: fn result -> send(parent, {:service_reply, result}) end
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    before = Manager.status(manager)

    args = %{
      "service" => "NickServ",
      "arguments" => ["REGISTER", "register-secret"],
      "scope" => "global",
      "channel" => nil
    }

    assert {:ok, _request_id} =
             Manager.request(manager, "root", %{"user" => user.uid}, "service", args, %{
               "actor_uid" => nil,
               "actor_user_rev" => nil,
               "actor_join_id" => nil,
               "target_user_rev" => nil,
               "target_join_id" => nil,
               "channel" => nil,
               "policy_epoch" => nil,
               "policy_revision" => nil
             })

    assert_receive {:service_reply, %{status: "OK", payload: %{"items" => items}}}, 2_000
    assert Enum.any?(items, &String.contains?(&1["trailing"], "successfully registered"))
    assert Manager.status(manager).policy_revision == before.policy_revision + 1
  end

  test "refreshes the authority projection after a committed C2S repository write" do
    boot = Identity.boot()
    policy_epoch = Identity.nonce()

    {:ok, manager} =
      Manager.start_link(
        config:
          config(boot)
          |> put_in([:s2s, :services_authority], "root")
          |> put_in([:s2s, :policy_epoch], policy_epoch),
        name: Manager
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    before = Manager.status()

    created =
      Output.transaction(
        fn ->
          RegisteredNicks.create(%{
            nickname: "CommittedC2S",
            registered_by: "c2s@test",
            password_hash: "test-hash"
          })
        end,
        drain_fun: &Dispatcher.drain_intent/1
      )

    assert created.nickname == "CommittedC2S"
    assert Manager.status().policy_revision == before.policy_revision + 1
    assert %{revision: revision} = PolicyStore.read()
    assert revision == before.policy_revision + 1

    runtime = Manager.runtime_view()
    assert {:ok, account} = Policy.get(runtime.policy, "account", created.account_id)
    assert account["canonical_name"] == "CommittedC2S"
    assert {:ok, nick} = Policy.get(runtime.policy, "nick", "committedc2s")
    assert nick["account_id"] == created.account_id
  end

  test "invalidates oversized policy changes and installs one complete authority image" do
    boot = Identity.boot()
    policy_epoch = Identity.nonce()

    {:ok, manager} =
      Manager.start_link(
        config:
          config(boot)
          |> put_in([:s2s, :services_authority], "root")
          |> put_in([:s2s, :policy_epoch], policy_epoch)
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    before = Manager.status(manager)

    Memento.transaction!(fn ->
      Enum.each(1..130, fn index ->
        Memento.Query.write(
          build(:registered_nick,
            nickname: "BulkPolicy#{index}",
            account_name: "BulkPolicy#{index}",
            password_hash: "test-hash"
          )
        )
      end)
    end)

    assert :ok = Manager.refresh_policy(manager)

    status = Manager.status(manager)
    runtime = Manager.runtime_view(manager)
    assert status.policy_revision == before.policy_revision + 1
    assert runtime.policy.ready? == true
    assert map_size(runtime.policy.objects) > 256
    assert PolicyStore.read().revision == status.policy_revision
  end

  test "does not refresh the authority projection after an aborted C2S repository write" do
    boot = Identity.boot()
    policy_epoch = Identity.nonce()

    {:ok, manager} =
      Manager.start_link(
        config:
          config(boot)
          |> put_in([:s2s, :services_authority], "root")
          |> put_in([:s2s, :policy_epoch], policy_epoch),
        name: Manager
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    before = Manager.status()

    assert_raise RuntimeError, fn ->
      Output.transaction(
        fn ->
          RegisteredNicks.create(%{
            nickname: "AbortedC2S",
            registered_by: "c2s@test",
            password_hash: "test-hash"
          })

          raise "abort C2S policy write"
        end,
        drain_fun: &Dispatcher.drain_intent/1
      )
    end

    assert {:error, :registered_nick_not_found} =
             Memento.transaction!(fn -> RegisteredNicks.get_by_nickname("AbortedC2S") end)

    assert Manager.status().policy_revision == before.policy_revision
    assert PolicyStore.read().revision == before.policy_revision
    assert Policy.get(Manager.runtime_view().policy, "nick", "abortedc2s") == :not_found
  end

  test "returns an authority-local global service reply through ENP for a live caller PID" do
    parent = self()
    boot = Identity.boot()

    receiver =
      spawn(fn ->
        loop = fn loop ->
          receive do
            message ->
              send(parent, {:service_c2s, message})
              loop.(loop)
          end
        end

        loop.(loop)
      end)

    on_exit(fn -> if Process.alive?(receiver), do: Process.exit(receiver, :kill) end)

    user =
      insert(:user,
        pid: receiver,
        nick: "LiveServiceCaller",
        home_sid: "root",
        home_boot: boot,
        registered: true
      )

    {:ok, manager} =
      Manager.start_link(
        config:
          config(boot)
          |> put_in([:s2s, :services_authority], "root")
          |> put_in([:s2s, :policy_epoch], Identity.nonce()),
        reply_fun: fn result -> send(parent, {:service_reply, result}) end
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    assert {:ok, _request_id} =
             Manager.request(
               manager,
               "root",
               %{"user" => user.uid},
               "service",
               %{"service" => "NickServ", "arguments" => ["HELP"], "scope" => "global", "channel" => nil},
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
             )

    assert_receive {:service_reply, %{status: "OK", payload: %{"items" => items}}}, 2_000
    assert items != []
    assert Enum.all?(items, &(&1["source"] == %{"service" => "NickServ"}))
    refute_receive {:service_c2s, _message}, 100
  end

  test "publishes verification policy before applying the owner's account binding" do
    parent = self()
    boot = Identity.boot()
    policy_epoch = Identity.nonce()

    registered_nick =
      insert(:registered_nick,
        nickname: "VerifyManager",
        verify_code: "manager-code",
        verified_at: nil
      )

    receiver =
      spawn(fn ->
        loop = fn loop ->
          receive do
            message ->
              send(parent, {:verify_c2s, message})
              loop.(loop)
          end
        end

        loop.(loop)
      end)

    on_exit(fn -> if Process.alive?(receiver), do: Process.exit(receiver, :kill) end)

    user =
      insert(:user,
        pid: receiver,
        nick: registered_nick.nickname,
        home_sid: "root",
        home_boot: boot,
        owner_rev: 1,
        registered: true,
        transport: :tls,
        modes: [],
        capabilities: ["account-notify"]
      )

    {:ok, manager} =
      Manager.start_link(
        config:
          config(boot)
          |> put_in([:s2s, :services_authority], "root")
          |> put_in([:s2s, :policy_epoch], policy_epoch),
        reply_fun: fn result -> send(parent, {:verify_reply, result}) end
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

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
             Manager.request(
               manager,
               "root",
               %{"user" => user.uid},
               "service",
               %{
                 "service" => "NickServ",
                 "arguments" => ["VERIFY", registered_nick.nickname, "manager-code"],
                 "scope" => "global",
                 "channel" => nil
               },
               guards
             )

    assert_receive {:verify_reply, %{status: "OK", payload: %{"items" => [], "result" => %{"accepted" => true}}}}, 2_000
    assert_receive {:verify_reply, %{status: "OK", payload: %{"items" => items}}}, 2_000
    assert Enum.any?(items, &String.contains?(&1["trailing"], "successfully verified"))

    assert_receive {:verify_c2s, {:broadcast, mode_message}}, 2_000
    assert mode_message =~ " +r"

    assert {:ok, updated_user} = Memento.transaction!(fn -> Users.get_by_uid(user.uid) end)
    assert updated_user.identified_as == registered_nick.account_name
    assert updated_user.sasl_authenticated == true
    assert :r in updated_user.modes
    assert updated_user.owner_rev == 3

    assert {:ok, verified} =
             Memento.transaction!(fn ->
               ElixIRCd.Repositories.RegisteredNicks.get_by_nickname(registered_nick.nickname)
             end)

    assert verified.verify_code == nil
    assert %DateTime{} = verified.verified_at
  end

  test "completes an authority-local RECOVER only after publishing its reservation" do
    parent = self()
    boot = Identity.boot()
    policy_epoch = Identity.nonce()
    registered_nick = insert(:registered_nick, nickname: "RecoveryNick")

    caller =
      insert(:user,
        nick: "RecoveryCaller",
        home_sid: "root",
        home_boot: boot,
        identified_as: registered_nick.account_name,
        registered: true,
        transport: :tls
      )

    {:ok, manager} =
      Manager.start_link(
        config:
          config(boot)
          |> put_in([:s2s, :services_authority], "root")
          |> put_in([:s2s, :policy_epoch], policy_epoch),
        reply_fun: fn result -> send(parent, {:recover_reply, result}) end
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    before = Manager.status(manager)

    assert {:ok, _request_id} =
             Manager.request(
               manager,
               "root",
               %{"user" => caller.uid},
               "service",
               %{
                 "service" => "NickServ",
                 "arguments" => ["RECOVER", registered_nick.nickname],
                 "scope" => "global",
                 "channel" => nil
               },
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
             )

    assert_receive {:recover_reply, %{status: "OK", payload: %{"items" => items}}}, 2_000
    assert Enum.any?(items, &String.contains?(&1["trailing"], "has been recovered"))
    assert Manager.status(manager).policy_revision == before.policy_revision + 1

    assert {:ok, updated} =
             Memento.transaction!(fn ->
               ElixIRCd.Repositories.RegisteredNicks.get_by_nickname(registered_nick.nickname)
             end)

    assert DateTime.compare(updated.reserved_until, DateTime.utc_now()) == :gt
  end

  test "clears a local binding when an applied policy revision deletes its account" do
    parent = self()
    boot = Identity.boot()
    policy_epoch = Identity.nonce()
    account = insert(:registered_nick, nickname: "PolicyAlice")

    receiver =
      spawn(fn ->
        loop = fn loop ->
          receive do
            message ->
              send(parent, {:policy_c2s, message})
              loop.(loop)
          end
        end

        loop.(loop)
      end)

    on_exit(fn -> if Process.alive?(receiver), do: Process.exit(receiver, :kill) end)

    user =
      insert(:user,
        pid: receiver,
        nick: "PolicyAlice",
        home_sid: "root",
        home_boot: boot,
        owner_rev: 1,
        identified_as: account.account_name,
        sasl_authenticated: true,
        registered: true,
        modes: [:r],
        capabilities: ["account-notify"]
      )

    {:ok, manager} =
      Manager.start_link(
        config:
          config(boot)
          |> put_in([:s2s, :services_authority], "root")
          |> put_in([:s2s, :policy_epoch], policy_epoch)
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    status = Manager.status(manager)

    assert :ok =
             Manager.publish_row(manager, %{
               "kind" => "policy.change",
               "epoch" => status.policy_epoch,
               "revision" => status.policy_revision + 1,
               "changes" => [%{"entity" => "account", "key" => account.account_id, "value" => nil}]
             })

    assert_receive {:policy_c2s, {:broadcast, mode_message}}
    assert mode_message =~ " MODE "
    assert mode_message =~ " -r"
    assert_receive {:policy_c2s, {:broadcast, logout_message}}
    assert logout_message =~ " 901 "
    assert_receive {:policy_c2s, {:broadcast, account_message}}
    assert account_message =~ " ACCOUNT *"

    assert {:ok, updated} = Memento.transaction!(fn -> Users.get_by_uid(user.uid) end)
    assert updated.identified_as == nil
    assert updated.sasl_authenticated == false
    refute :r in updated.modes
  end

  test "materializes authority-owned ChanServ status through a stamped row" do
    parent = self()
    boot = Identity.boot()
    policy_epoch = Identity.nonce()

    caller_receiver =
      spawn(fn ->
        loop = fn loop ->
          receive do
            message ->
              send(parent, {:status_c2s, message})
              loop.(loop)
          end
        end

        loop.(loop)
      end)

    target_receiver =
      spawn(fn ->
        loop = fn loop ->
          receive do
            message ->
              send(parent, {:status_c2s, message})
              loop.(loop)
          end
        end

        loop.(loop)
      end)

    on_exit(fn ->
      if Process.alive?(caller_receiver), do: Process.exit(caller_receiver, :kill)
      if Process.alive?(target_receiver), do: Process.exit(target_receiver, :kill)
    end)

    insert(:registered_nick, nickname: "Founder", account_name: "Founder")

    caller =
      insert(:user,
        pid: caller_receiver,
        nick: "FounderClient",
        home_sid: "root",
        home_boot: boot,
        identified_as: "Founder",
        registered: true
      )

    target =
      insert(:user,
        pid: target_receiver,
        nick: "Target",
        home_sid: "root",
        home_boot: boot,
        registered: true
      )

    channel = insert(:channel, name: "#status-row")
    insert(:registered_channel, name: channel.name, founder: "Founder")
    insert(:user_channel, user: caller, channel: channel, join_id: 11)
    insert(:user_channel, user: target, channel: channel, join_id: 12)

    {:ok, manager} =
      Manager.start_link(
        config:
          config(boot)
          |> put_in([:s2s, :services_authority], "root")
          |> put_in([:s2s, :policy_epoch], policy_epoch),
        reply_fun: fn result -> send(parent, {:status_reply, result}) end
      )

    Process.unlink(manager)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    args = %{
      "service" => "ChanServ",
      "arguments" => ["OP", channel.name, target.nick],
      "scope" => "global",
      "channel" => nil
    }

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
             Manager.request(manager, "root", %{"user" => caller.uid}, "service", args, guards)

    assert_receive {:status_c2s, {:broadcast, first_mode}}, 2_000
    assert first_mode =~ " MODE #status-row +o Target"
    assert_receive {:status_c2s, {:broadcast, second_mode}}, 2_000
    assert second_mode =~ " MODE #status-row +o Target"
    assert_receive {:status_reply, %{status: "OK", done: true, payload: %{"items" => items}}}, 2_000
    assert Enum.any?(items, &String.contains?(&1["trailing"], "Operator status granted"))

    assert updated_membership = Memento.transaction!(fn -> UserChannels.get_by_uid(target.uid) |> List.first() end)

    assert :o in updated_membership.modes
  end

  test "blocks new origin work during bounded graceful shutdown" do
    boot = Identity.boot()
    shutdown_config = put_in(config(boot), [:s2s, :timeouts, :shutdown_ms], 100)

    {:ok, manager} = Manager.start_link(config: shutdown_config)
    Process.unlink(manager)

    assert :ok = Manager.shutdown(manager)
    assert Manager.status(manager).lifecycle == :closing
    assert {:error, :shutting_down} = Manager.refresh_policy(manager)

    assert eventually(fn -> not Process.alive?(manager) end, 30)
  end

  defp eventually(fun, attempts)

  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
