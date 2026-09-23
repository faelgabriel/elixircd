defmodule ElixIRCd.Server.S2S.ServiceEndpointTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.Memos
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Policy
  alias ElixIRCd.Server.S2S.ServiceEndpoint
  alias ElixIRCd.Tables.User

  defp runtime(uid) do
    %{
      users: %{
        uid => %{
          "uid" => uid,
          "home" => %{"sid" => "leaf", "boot" => Identity.boot()},
          "rev" => 1,
          "requested_nick" => "Alice",
          "effective_nick" => "Alice",
          "signon_ms" => 1_700_000_000_000,
          "ident" => "alice",
          "realhost" => "client.example",
          "displayhost" => "client.example",
          "address" => "192.0.2.10",
          "secure_client" => true,
          "modes" => [],
          "realname" => "Alice Example",
          "binding" => nil
        }
      },
      policy: Policy.new(epoch: Identity.nonce(), revision: 1, ready?: true)
    }
  end

  defp channel_runtime(caller_uid, target_uid, channel_name \\ "#native") do
    boot = Identity.boot()
    cid = Identity.cid()
    account = insert(:registered_nick, nickname: "Founder", account_name: "Founder")
    channel = insert(:registered_channel, name: channel_name, founder: account.account_name)

    {:ok, policy} =
      Policy.from_sources(
        Identity.nonce(),
        [account],
        [channel],
        [],
        [],
        revision: 1
      )

    ref = %{"name" => channel_name, "born_ms" => 10, "cid" => cid}

    runtime(caller_uid)
    |> Map.merge(%{
      sid: "root",
      boot: boot,
      services_authority: "root",
      policy: policy,
      channels: %{
        String.downcase(channel_name) => %{
          ref: ref,
          registers: %{},
          list_slots: %{},
          statuses: %{
            {caller_uid, 1, "o"} => %{value: %{enabled: true}}
          }
        }
      },
      users: %{
        caller_uid => %{
          "uid" => caller_uid,
          "home" => %{"sid" => "root", "boot" => boot},
          "rev" => 1,
          "requested_nick" => "Alice",
          "effective_nick" => "Alice",
          "signon_ms" => 1_700_000_000_000,
          "ident" => "alice",
          "realhost" => "client.example",
          "displayhost" => "client.example",
          "address" => "192.0.2.10",
          "secure_client" => true,
          "modes" => [],
          "realname" => "Alice Example",
          "binding" => %{
            "account_id" => account.account_id,
            "auth_epoch" => account.auth_epoch,
            "policy_epoch" => policy.epoch
          }
        },
        target_uid => %{
          "uid" => target_uid,
          "home" => %{"sid" => "leaf", "boot" => Identity.boot()},
          "rev" => 4,
          "requested_nick" => "Target",
          "effective_nick" => "Target",
          "signon_ms" => 1_700_000_000_000,
          "ident" => "target",
          "realhost" => "client.example",
          "displayhost" => "client.example",
          "address" => "192.0.2.11",
          "secure_client" => true,
          "modes" => [],
          "realname" => "Target Example",
          "binding" => nil
        }
      },
      memberships: %{
        caller_uid => %{
          rev: 1,
          home: %{"sid" => "root", "boot" => boot},
          entries: [%{"channel" => String.downcase(channel_name), "join_id" => 1, "joined_ms" => 1}]
        },
        target_uid => %{
          rev: 2,
          home: %{"sid" => "leaf", "boot" => Identity.boot()},
          entries: [%{"channel" => String.downcase(channel_name), "join_id" => 7, "joined_ms" => 2}]
        }
      }
    })
  end

  test "dispatches read-only HELP as structured multipart service replies" do
    uid = Identity.uid()

    frame = %{
      "actor" => %{"user" => uid},
      "args" => %{
        "service" => "NickServ",
        "arguments" => ["HELP"],
        "scope" => "global",
        "channel" => nil
      }
    }

    assert {:ok, {:stream, parts}} =
             ServiceEndpoint.execute(frame, runtime(uid), %{local_sid: "root", services_authority: "root"})

    items = Enum.flat_map(parts, & &1["items"])
    assert length(items) > 1
    assert Enum.all?(items, &(&1["source"] == %{"service" => "NickServ"}))
    assert Enum.all?(items, &(&1["command"] == "NOTICE"))
  end

  test "requires the services authority and a ready policy for global requests" do
    uid = Identity.uid()

    frame = %{
      "actor" => %{"user" => uid},
      "args" => %{
        "service" => "NickServ",
        "arguments" => ["STATUS"],
        "scope" => "global",
        "channel" => nil
      }
    }

    assert {:error, "UNAVAILABLE", "services authority is elsewhere"} =
             ServiceEndpoint.execute(frame, runtime(uid), %{local_sid: "leaf", services_authority: "root"})

    not_ready_runtime = %{runtime(uid) | policy: %{runtime(uid).policy | ready?: false}}

    assert {:error, "UNAVAILABLE", "service policy is not ready"} =
             ServiceEndpoint.execute(frame, not_ready_runtime, %{local_sid: "root", services_authority: "root"})

    local_frame = update_in(frame, ["args"], &Map.put(&1, "scope", "local"))

    assert {:error, "UNSUPPORTED", "service operation is not enabled"} =
             ServiceEndpoint.execute(local_frame, runtime(uid), %{local_sid: "root", services_authority: "root"})

    malformed_frame = update_in(frame, ["args"], &Map.put(&1, "arguments", ["STATUS", :invalid]))

    assert {:error, "REJECTED", "service arguments must be text"} =
             ServiceEndpoint.execute(malformed_frame, runtime(uid), %{local_sid: "root", services_authority: "root"})
  end

  test "stores private MEMO delivery without publishing a public policy revision" do
    uid = Identity.uid()
    sender = insert(:registered_nick, nickname: "MemoSender", account_name: "MemoSender")
    recipient = insert(:registered_nick, nickname: "MemoRecipient", account_name: "MemoRecipient")

    {:ok, policy} = Policy.from_sources(Identity.nonce(), [sender, recipient], [], [], [], revision: 7)

    remote_runtime =
      runtime(uid)
      |> Map.merge(%{sid: "root", boot: Identity.boot(), services_authority: "root", policy: policy})
      |> put_in([:users, uid, "requested_nick"], sender.nickname)
      |> put_in([:users, uid, "effective_nick"], sender.nickname)
      |> put_in([:users, uid, "home"], %{"sid" => "leaf", "boot" => Identity.boot()})
      |> put_in([:users, uid, "binding"], %{
        "account_id" => sender.account_id,
        "auth_epoch" => sender.auth_epoch,
        "policy_epoch" => policy.epoch
      })

    frame = %{
      "actor" => %{"user" => uid},
      "args" => %{
        "service" => "NickServ",
        "arguments" => ["MEMO", "SEND", recipient.nickname, "private", "message"],
        "scope" => "global",
        "channel" => nil
      }
    }

    assert {:ok, {:stream, parts}} =
             ServiceEndpoint.execute(frame, remote_runtime, %{local_sid: "root", services_authority: "root"})

    items = Enum.flat_map(parts, & &1["items"])
    assert Enum.any?(items, &String.contains?(&1["trailing"], "delivered"))

    assert [%{sender_account: "MemoSender", body: "private message"}] =
             Memento.transaction!(fn -> Memos.get_by_recipient(recipient.account_name) end)

    assert policy.revision == 7
  end

  test "executes the global read-only service families from a remote projection" do
    uid = Identity.uid()
    account = insert(:registered_nick, nickname: "Alice", account_name: "Alice")

    {:ok, policy} = Policy.from_sources(Identity.nonce(), [account], [], [], [], revision: 1)

    remote_runtime =
      runtime(uid)
      |> Map.merge(%{sid: "root", boot: Identity.boot(), services_authority: "root", policy: policy})
      |> put_in([:users, uid, "home"], %{"sid" => "leaf", "boot" => Identity.boot()})
      |> put_in([:users, uid, "binding"], %{
        "account_id" => account.account_id,
        "auth_epoch" => account.auth_epoch,
        "policy_epoch" => policy.epoch
      })

    nickserv_commands = [
      ["ALIST"],
      ["ACCESS", "LIST"],
      ["HELP"],
      ["INFO"],
      ["LIST"],
      ["LISTCHANS"],
      ["MEMO", "LIST"],
      ["STATUS", "Alice"],
      ["SET", "NOGREET"]
    ]

    Enum.each(nickserv_commands, fn arguments ->
      frame = %{
        "actor" => %{"user" => uid},
        "args" => %{
          "service" => "NickServ",
          "arguments" => arguments,
          "scope" => "global",
          "channel" => nil
        }
      }

      result = ServiceEndpoint.execute(frame, remote_runtime, %{local_sid: "root", services_authority: "root"})
      assert match?({:ok, _}, result), "NickServ #{inspect(arguments)} returned #{inspect(result)}"
    end)

    channel_runtime = channel_runtime(uid, Identity.uid())

    chanserv_commands = [
      ["ACCESS", "#native", "LIST"],
      ["ALIST"],
      ["FLAGS", "#native"],
      ["HELP"],
      ["INFO", "#native"],
      ["SET", "#native", "PRIVATE"],
      ["STATUS", "#native"]
    ]

    Enum.each(chanserv_commands, fn arguments ->
      frame = %{
        "actor" => %{"user" => uid},
        "args" => %{
          "service" => "ChanServ",
          "arguments" => arguments,
          "scope" => "global",
          "channel" => nil
        }
      }

      result = ServiceEndpoint.execute(frame, channel_runtime, %{local_sid: "root", services_authority: "root"})
      assert match?({:ok, _}, result), "ChanServ #{inspect(arguments)} returned #{inspect(result)}"
    end)
  end

  test "executes only status operations from a channel-scoped ChanServ request" do
    caller_uid = Identity.uid()
    target_uid = Identity.uid()
    runtime = channel_runtime(caller_uid, target_uid)

    frame = %{
      "actor" => %{"user" => caller_uid},
      "args" => %{
        "service" => "ChanServ",
        "arguments" => ["OP", "#native", "Target"],
        "scope" => "channel",
        "channel" => "#native"
      }
    }

    assert {:ok, payload, _rows} =
             ServiceEndpoint.execute(frame, runtime, %{local_sid: "root", services_authority: "root"})

    items = payload["items"]
    assert Enum.any?(items, &String.contains?(&1["trailing"], "Operator status granted"))

    invalid = put_in(frame, ["args", "arguments"], ["HELP"])

    assert {:error, "UNSUPPORTED", "invalid channel service scope"} =
             ServiceEndpoint.execute(invalid, runtime, %{local_sid: "root", services_authority: "root"})
  end

  test "executes authority-owned registration through a remote user projection" do
    uid = Identity.uid()

    frame = %{
      "actor" => %{"user" => uid},
      "args" => %{
        "service" => "NickServ",
        "arguments" => ["REGISTER", "secret"],
        "scope" => "global",
        "channel" => nil
      }
    }

    assert {:ok, {:stream, parts}, [policy_row]} =
             ServiceEndpoint.execute(frame, runtime(uid), %{local_sid: "root", services_authority: "root"})

    items = Enum.flat_map(parts, & &1["items"])
    assert Enum.any?(items, &String.contains?(&1["trailing"], "successfully registered"))
    assert policy_row["kind"] == "policy.change"
  end

  test "commits the remaining global service mutations through the authority adapter" do
    uid = Identity.uid()
    account = insert(:registered_nick, nickname: "Alice", account_name: "Alice")
    target_nick = insert(:registered_nick, nickname: "Target", account_name: "Target")

    {:ok, policy} = Policy.from_sources(Identity.nonce(), [account, target_nick], [], [], [], revision: 1)

    remote_runtime =
      runtime(uid)
      |> Map.merge(%{sid: "root", boot: Identity.boot(), services_authority: "root", policy: policy})
      |> put_in([:users, uid, "requested_nick"], "NewAlias")
      |> put_in([:users, uid, "effective_nick"], "NewAlias")
      |> put_in([:users, uid, "home"], %{"sid" => "leaf", "boot" => Identity.boot()})
      |> put_in([:users, uid, "binding"], %{
        "account_id" => account.account_id,
        "auth_epoch" => account.auth_epoch,
        "policy_epoch" => policy.epoch
      })

    service = fn name, arguments ->
      %{
        "actor" => %{"user" => uid},
        "args" => %{"service" => name, "arguments" => arguments, "scope" => "global", "channel" => nil}
      }
    end

    assert {:ok, {:stream, _}, group_rows} =
             ServiceEndpoint.execute(service.("NickServ", ["GROUP"]), remote_runtime, %{
               local_sid: "root",
               services_authority: "root"
             })

    assert Enum.any?(group_rows, &(&1["kind"] == "policy.change"))

    assert {:ok, {:stream, _}, set_rows} =
             ServiceEndpoint.execute(service.("NickServ", ["SET", "NOGREET", "ON"]), remote_runtime, %{
               local_sid: "root",
               services_authority: "root"
             })

    assert Enum.any?(set_rows, &(&1["kind"] == "policy.change"))

    channel_runtime = channel_runtime(uid, Identity.uid())

    assert {:ok, {:stream, _}, access_rows} =
             ServiceEndpoint.execute(
               service.("ChanServ", ["ACCESS", "#native", "ADD", "Target", "1"]),
               channel_runtime,
               %{
                 local_sid: "root",
                 services_authority: "root"
               }
             )

    assert Enum.any?(access_rows, &(&1["kind"] == "policy.change"))

    assert {:ok, {:stream, _}, flags_rows} =
             ServiceEndpoint.execute(service.("ChanServ", ["FLAGS", "#native", "Target", "+v"]), channel_runtime, %{
               local_sid: "root",
               services_authority: "root"
             })

    assert Enum.any?(flags_rows, &(&1["kind"] == "policy.change"))

    assert {:ok, {:stream, _}, set_channel_rows} =
             ServiceEndpoint.execute(service.("ChanServ", ["SET", "#native", "PRIVATE", "ON"]), channel_runtime, %{
               local_sid: "root",
               services_authority: "root"
             })

    assert Enum.any?(set_channel_rows, &(&1["kind"] == "policy.change"))
  end

  test "commits and fences NickServ reservation follow-ups" do
    registered_nick = insert(:registered_nick, nickname: "HeldNative")
    expires_at_ms = Identity.now_ms() + 5_000

    assert {:ok, [reserve_row]} =
             ServiceEndpoint.apply_follow_up(
               %{
                 "kind" => "reserve_nick",
                 "nickname" => registered_nick.nickname,
                 "expires_at_ms" => expires_at_ms
               },
               runtime(Identity.uid())
             )

    assert reserve_row["kind"] == "policy.change"

    assert {:ok, reserved} =
             Memento.transaction!(fn ->
               ElixIRCd.Repositories.RegisteredNicks.get_by_nickname(registered_nick.nickname)
             end)

    assert DateTime.to_unix(reserved.reserved_until, :millisecond) == expires_at_ms

    assert {:error, "STALE", "nickname is already reserved"} =
             ServiceEndpoint.apply_follow_up(
               %{
                 "kind" => "reserve_nick",
                 "nickname" => registered_nick.nickname,
                 "expires_at_ms" => expires_at_ms + 1_000
               },
               runtime(Identity.uid())
             )

    assert {:ok, [clear_row]} =
             ServiceEndpoint.apply_follow_up(
               %{
                 "kind" => "clear_nick_reservation",
                 "nickname" => registered_nick.nickname,
                 "expected_expires_at_ms" => expires_at_ms
               },
               runtime(Identity.uid())
             )

    assert clear_row["kind"] == "policy.change"

    assert {:ok, cleared} =
             Memento.transaction!(fn ->
               ElixIRCd.Repositories.RegisteredNicks.get_by_nickname(registered_nick.nickname)
             end)

    assert cleared.reserved_until == nil
  end

  test "turns global ChanServ KICK into one guarded owner action" do
    caller_uid = Identity.uid()
    target_uid = Identity.uid()
    runtime = channel_runtime(caller_uid, target_uid)

    caller =
      User.new(%{
        uid: caller_uid,
        pid: nil,
        nick: "Alice",
        effective_nick: "Alice",
        identified_as: "Founder",
        registered: true,
        home_sid: "root",
        home_boot: runtime.boot,
        transport: :tls,
        ip_address: {192, 0, 2, 10},
        port_connected: 6697,
        hostname: "client.example",
        ident: "alice",
        created_at: DateTime.utc_now()
      })

    assert {:owner_action, action} =
             ServiceEndpoint.chanserv_kick_job(["KICK", "#native", "Target", "reason"], caller, runtime)

    assert action.method == "user_action"
    assert action.actor == %{"service" => "ChanServ"}
    assert action.target_sid == "leaf"
    assert action.args["action"] == "kick"
    assert action.args["target_uid"] == target_uid
    assert action.args["value"]["join_id"] == 7
    assert action.args["value"]["channel"] == runtime.channels["#native"].ref
    assert action.guards["target_user_rev"] == 4
  end

  test "turns global ChanServ INVITE into one owner delivery" do
    caller_uid = Identity.uid()
    target_uid = Identity.uid()
    runtime = channel_runtime(caller_uid, target_uid)

    runtime = %{
      runtime
      | memberships: Map.put(runtime.memberships, target_uid, %{runtime.memberships[target_uid] | entries: []})
    }

    caller =
      User.new(%{
        uid: caller_uid,
        pid: nil,
        nick: "Alice",
        effective_nick: "Alice",
        identified_as: "Founder",
        registered: true,
        home_sid: "root",
        home_boot: runtime.boot,
        transport: :tls,
        ip_address: {192, 0, 2, 10},
        port_connected: 6697,
        hostname: "client.example",
        ident: "alice",
        created_at: DateTime.utc_now()
      })

    assert {:owner_action, action} =
             ServiceEndpoint.chanserv_invite_job(["INVITE", "#native", "Target"], caller, runtime)

    assert action.method == "invite"
    assert action.actor == %{"service" => "ChanServ"}
    assert action.target_sid == "leaf"
    assert action.args["inviter_uid"] == caller_uid
    assert action.args["target_uid"] == target_uid
    assert action.args["channel"] == runtime.channels["#native"].ref
  end

  test "registers a remote live channel from the authority projection" do
    caller_uid = Identity.uid()
    target_uid = Identity.uid()
    runtime = channel_runtime(caller_uid, target_uid, "#register-native")

    assert {:ok, registered_channel} =
             Memento.transaction!(fn ->
               ElixIRCd.Repositories.RegisteredChannels.get_by_name("#register-native")
             end)

    assert :ok = Memento.transaction!(fn -> ElixIRCd.Repositories.RegisteredChannels.delete(registered_channel) end)

    policy = %{
      runtime.policy
      | objects: Map.reject(runtime.policy.objects, fn {{entity, _key}, _value} -> entity == "channel" end)
    }

    runtime = %{runtime | policy: policy}

    frame = %{
      "actor" => %{"user" => caller_uid},
      "args" => %{
        "service" => "ChanServ",
        "arguments" => ["REGISTER", "#register-native", "register-secret"],
        "scope" => "global",
        "channel" => nil
      }
    }

    assert {:ok, _payload, [policy_row]} =
             ServiceEndpoint.execute(frame, runtime, %{local_sid: "root", services_authority: "root"})

    assert policy_row["kind"] == "policy.change"

    assert {:ok, registered} =
             Memento.transaction!(fn ->
               ElixIRCd.Repositories.RegisteredChannels.get_by_name("#register-native")
             end)

    assert registered.founder == "Founder"
  end

  test "defers ChanServ REGISTER when called from the manager request path" do
    caller_uid = Identity.uid()
    target_uid = Identity.uid()
    runtime = channel_runtime(caller_uid, target_uid, "#native")
    live_channel = runtime.channels["#native"]
    live_channel = %{live_channel | ref: Map.put(live_channel.ref, "name", "#register-deferred")}
    runtime = %{runtime | channels: %{"#register-deferred" => live_channel}}

    frame = %{
      "actor" => %{"user" => caller_uid},
      "args" => %{
        "service" => "ChanServ",
        "arguments" => ["REGISTER", "#register-deferred", "register-secret"],
        "scope" => "global",
        "channel" => nil
      }
    }

    assert {:async_deferred, job} =
             ServiceEndpoint.execute(frame, runtime, %{
               local_sid: "root",
               services_authority: "root",
               defer_expensive?: true
             })

    assert {:deferred_transaction, commit_fun} = job.()
    assert is_function(commit_fun, 0)

    assert {:error, :registered_channel_not_found} =
             Memento.transaction!(fn ->
               ElixIRCd.Repositories.RegisteredChannels.get_by_name("#register-deferred")
             end)

    assert {:state_rows, _payload, [_policy_row]} = commit_fun.()

    assert {:ok, registered} =
             Memento.transaction!(fn ->
               ElixIRCd.Repositories.RegisteredChannels.get_by_name("#register-deferred")
             end)

    assert registered.founder == "Founder"
  end

  test "keeps remote NickServ IDENTIFY verification outside the state transaction" do
    uid = Identity.uid()
    account = insert(:registered_nick, nickname: "DeferredAlice", password: "deferred-secret")
    {:ok, policy} = Policy.from_sources(Identity.nonce(), [account], [], [], [], revision: 1)

    remote_runtime =
      runtime(uid)
      |> Map.merge(%{sid: "root", services_authority: "root", policy: policy})
      |> put_in([:users, uid, "home"], %{"sid" => "leaf", "boot" => Identity.boot()})

    frame = %{
      "actor" => %{"user" => uid},
      "args" => %{
        "service" => "NickServ",
        "arguments" => ["IDENTIFY", "DeferredAlice", "deferred-secret"],
        "scope" => "global",
        "channel" => nil
      }
    }

    assert {:async_deferred, job} =
             ServiceEndpoint.execute(frame, remote_runtime, %{
               local_sid: "root",
               services_authority: "root",
               defer_expensive?: true
             })

    assert {:deferred_transaction, commit_fun} = job.()

    assert {:ok, before_commit} =
             Memento.transaction!(fn ->
               ElixIRCd.Repositories.RegisteredNicks.get_by_nickname("DeferredAlice")
             end)

    assert {:owner_action, action} = commit_fun.()
    assert action.target_sid == "leaf"

    assert {:ok, after_commit} =
             Memento.transaction!(fn ->
               ElixIRCd.Repositories.RegisteredNicks.get_by_nickname("DeferredAlice")
             end)

    assert after_commit.last_seen_at != before_commit.last_seen_at
  end

  test "defers NickServ REGISTER password hashing before its policy transaction" do
    uid = Identity.uid()

    frame = %{
      "actor" => %{"user" => uid},
      "args" => %{
        "service" => "NickServ",
        "arguments" => ["REGISTER", "deferred-secret"],
        "scope" => "global",
        "channel" => nil
      }
    }

    assert {:async_deferred, job} =
             ServiceEndpoint.execute(frame, runtime(uid), %{
               local_sid: "root",
               services_authority: "root",
               defer_expensive?: true
             })

    assert {:deferred_transaction, commit_fun} = job.()

    assert {:error, :registered_nick_not_found} =
             Memento.transaction!(fn ->
               ElixIRCd.Repositories.RegisteredNicks.get_by_nickname("Alice")
             end)

    assert {:state_rows, {:stream, _parts}, [_policy_row]} = commit_fun.()

    assert {:ok, registered} =
             Memento.transaction!(fn ->
               ElixIRCd.Repositories.RegisteredNicks.get_by_nickname("Alice")
             end)

    assert registered.password_hash != "deferred-secret"
  end

  test "defers password based NickServ DROP before its policy transaction" do
    uid = Identity.uid()
    registered_nick = insert(:registered_nick, nickname: "DeferredDrop", password: "drop-secret")
    {:ok, policy} = Policy.from_sources(Identity.nonce(), [registered_nick], [], [], [], revision: 1)

    remote_runtime =
      runtime(uid)
      |> Map.merge(%{sid: "root", services_authority: "root", policy: policy})
      |> put_in([:users, uid, "requested_nick"], "DeferredDrop")
      |> put_in([:users, uid, "effective_nick"], "DeferredDrop")

    frame = %{
      "actor" => %{"user" => uid},
      "args" => %{
        "service" => "NickServ",
        "arguments" => ["DROP", "DeferredDrop", "drop-secret"],
        "scope" => "global",
        "channel" => nil
      }
    }

    assert {:async_deferred, job} =
             ServiceEndpoint.execute(frame, remote_runtime, %{
               local_sid: "root",
               services_authority: "root",
               defer_expensive?: true
             })

    assert {:deferred_transaction, commit_fun} = job.()
    assert {:state_rows, {:stream, _parts}, _rows} = commit_fun.()

    assert {:error, :registered_nick_not_found} =
             Memento.transaction!(fn ->
               ElixIRCd.Repositories.RegisteredNicks.get_by_nickname("DeferredDrop")
             end)
  end

  test "verifies a remote nickname before returning its owner binding action" do
    uid = Identity.uid()
    registered_nick = insert(:registered_nick, nickname: "VerifyMe", verify_code: "verify-code", verified_at: nil)
    {:ok, policy} = Policy.from_sources(Identity.nonce(), [registered_nick], [], [], [], revision: 1)

    remote_runtime =
      runtime(uid)
      |> Map.put(:sid, "root")
      |> Map.put(:services_authority, "root")
      |> Map.put(:policy, policy)
      |> put_in([:users, uid, "requested_nick"], "VerifyMe")
      |> put_in([:users, uid, "effective_nick"], "VerifyMe")
      |> put_in([:users, uid, "home"], %{"sid" => "leaf", "boot" => Identity.boot()})

    frame = %{
      "actor" => %{"user" => uid},
      "args" => %{
        "service" => "NickServ",
        "arguments" => ["VERIFY", "VerifyMe", "verify-code"],
        "scope" => "global",
        "channel" => nil
      }
    }

    assert {:async, job} =
             ServiceEndpoint.execute(frame, remote_runtime, %{local_sid: "root", services_authority: "root"})

    assert {:owner_action, action} = job.()
    assert action.target_sid == "leaf"
    assert action.actor == %{"service" => "NickServ"}
    assert action.args["action"] == "account"
    assert action.args["target_uid"] == uid
    assert action.args["value"]["binding"]["account_id"] == registered_nick.account_id
    assert length(action.pre_rows) == 1
    assert action.pre_rows |> hd() |> Map.fetch!("kind") == "policy.change"

    assert {:ok, verified} =
             Memento.transaction!(fn ->
               ElixIRCd.Repositories.RegisteredNicks.get_by_nickname("VerifyMe")
             end)

    assert verified.verify_code == nil
    assert %DateTime{} = verified.verified_at
  end

  test "publishes guarded ChanServ BAN and UNBAN rows from the authority" do
    caller_uid = Identity.uid()
    target_uid = Identity.uid()
    runtime = channel_runtime(caller_uid, target_uid)

    caller =
      User.new(%{
        uid: caller_uid,
        pid: nil,
        nick: "Alice",
        effective_nick: "Alice",
        identified_as: "Founder",
        registered: true,
        home_sid: "root",
        home_boot: runtime.boot,
        transport: :tls,
        ip_address: {192, 0, 2, 10},
        port_connected: 6697,
        hostname: "client.example",
        ident: "alice",
        created_at: DateTime.utc_now()
      })

    assert {:ok, _payload, [ban_row]} =
             ServiceEndpoint.chanserv_list_job("BAN", ["BAN", "#native", "Target"], caller, runtime)

    assert ban_row["kind"] == "channel.list"
    assert ban_row["mode"] == "b"
    assert ban_row["present"] == true
    assert ban_row["channel"] == runtime.channels["#native"].ref

    assert {:ok, ban} =
             Memento.transaction!(fn ->
               ElixIRCd.Repositories.ChannelBans.get_by_channel_name_key_and_mask("#native", ban_row["mask"])
             end)

    assert ban.mask == ban_row["mask"]

    assert {:ok, _payload, [unban_row]} =
             ServiceEndpoint.chanserv_list_job("UNBAN", ["UNBAN", "#native", "Target"], caller, runtime)

    assert unban_row["mode"] == "b"
    assert unban_row["present"] == false

    assert {:error, :channel_ban_not_found} =
             Memento.transaction!(fn ->
               ElixIRCd.Repositories.ChannelBans.get_by_channel_name_key_and_mask("#native", ban_row["mask"])
             end)
  end

  test "turns remote NickServ UNGROUP into a new account binding after policy publication" do
    uid = Identity.uid()
    account = insert(:registered_nick, nickname: "PrimaryNative")

    alias_nick =
      insert(:registered_nick,
        nickname: "AliasNative",
        account_name: account.nickname,
        account_id: account.account_id,
        auth_epoch: account.auth_epoch,
        settings: account.settings
      )

    {:ok, policy} = Policy.from_sources(Identity.nonce(), [account, alias_nick], [], [], [], revision: 1)

    remote_runtime =
      runtime(uid)
      |> Map.merge(%{sid: "root", boot: Identity.boot(), services_authority: "root", policy: policy})
      |> put_in([:users, uid, "requested_nick"], alias_nick.nickname)
      |> put_in([:users, uid, "effective_nick"], alias_nick.nickname)
      |> put_in([:users, uid, "home"], %{"sid" => "leaf", "boot" => Identity.boot()})
      |> put_in([:users, uid, "binding"], %{
        "account_id" => account.account_id,
        "auth_epoch" => account.auth_epoch,
        "policy_epoch" => policy.epoch
      })

    frame = %{
      "actor" => %{"user" => uid},
      "args" => %{
        "service" => "NickServ",
        "arguments" => ["UNGROUP"],
        "scope" => "global",
        "channel" => nil
      }
    }

    assert {:async, job} =
             ServiceEndpoint.execute(frame, remote_runtime, %{local_sid: "root", services_authority: "root"})

    assert {:owner_action, action} = job.()
    assert action.target_sid == "leaf"
    assert action.args["action"] == "account"
    assert action.args["value"]["binding"]["account_id"] != account.account_id
    assert length(action.pre_rows) == 1

    assert {:ok, detached} =
             Memento.transaction!(fn ->
               ElixIRCd.Repositories.RegisteredNicks.get_by_nickname(alias_nick.nickname)
             end)

    assert detached.account_name == alias_nick.nickname
    assert detached.account_id == action.args["value"]["binding"]["account_id"]
  end
end
