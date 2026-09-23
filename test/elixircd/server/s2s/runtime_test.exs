defmodule ElixIRCd.Server.S2S.RuntimeTest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Policy
  alias ElixIRCd.Server.S2S.Runtime
  alias ElixIRCd.Server.S2S.State

  defp config do
    [
      s2s: [
        server_id: "root",
        roster: [[sid: "root", name: "root.example.test", parent: nil]],
        policy_epoch: Identity.nonce()
      ],
      settings: [case_mapping: :ascii]
    ]
  end

  defp branching_config do
    [
      s2s: [
        server_id: "root",
        roster: [
          [sid: "root", name: "root.example.test", parent: nil],
          [sid: "leaf", name: "leaf.example.test", parent: "root"]
        ],
        policy_epoch: Identity.nonce()
      ],
      settings: [case_mapping: :ascii]
    ]
  end

  defp user(uid, boot) do
    %{
      "uid" => uid,
      "home" => %{"sid" => "root", "boot" => boot},
      "rev" => 1,
      "requested_nick" => "Rafael",
      "signon_ms" => 1,
      "ident" => "rafael",
      "realhost" => "client.example",
      "displayhost" => "client.example",
      "address" => "192.0.2.1",
      "secure_client" => true,
      "client_certfp" => nil,
      "modes" => [],
      "oper_role" => nil,
      "away" => nil,
      "realname" => "Rafael",
      "binding" => nil
    }
  end

  defp account(id) do
    %{
      "account_id" => id,
      "canonical_name" => "account",
      "display_name" => "Account",
      "auth_epoch" => 1,
      "verified" => true,
      "aliases" => ["account"],
      "settings" => %{
        "enforce" => false,
        "enforce_time" => 0,
        "kill" => "off",
        "hide_status" => false,
        "hide_usermask" => false,
        "hide_quit" => false,
        "never_op" => false,
        "no_greet" => false,
        "quiet_chg" => false,
        "secure" => false
      }
    }
  end

  test "applies user, membership, channel and stamped field rows" do
    {:ok, runtime} = Runtime.new(config())
    uid = Identity.uid()
    channel = %{"name" => "#chat", "born_ms" => 1, "cid" => Identity.cid()}
    user = user(uid, runtime.boot)

    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => user})
    membership = %{"channel" => "#chat", "join_id" => 1, "joined_ms" => 2}
    cause = %{"action" => "join", "channel" => "#chat", "join_id" => 1, "by" => %{"user" => uid}, "reason" => "join"}

    assert {:ok, runtime, _} =
             Runtime.apply_local_row(runtime, %{
               "kind" => "memberships.put",
               "uid" => uid,
               "home" => user["home"],
               "rev" => 1,
               "entries" => [membership],
               "cause" => cause
             })

    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "channel.ensure", "channel" => channel})

    stamp = [1, "root", runtime.boot]

    field = %{
      "kind" => "channel.field",
      "channel" => channel,
      "field" => "topic",
      "value" => %{"text" => "hello", "setter" => "Rafael", "set_ms" => 3},
      "stamp" => stamp,
      "setter" => %{"user" => uid}
    }

    assert {:ok, runtime, effects} = Runtime.apply_local_row(runtime, field)
    assert effects != []
    assert runtime.channels["#chat"].registers["topic"].value["text"] == "hello"

    status = %{
      "kind" => "member.status",
      "channel" => channel,
      "uid" => uid,
      "join_id" => 1,
      "mode" => "o",
      "enabled" => true,
      "stamp" => [2, "root", runtime.boot],
      "setter" => %{"user" => uid}
    }

    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, status)
    assert map_size(runtime.channels["#chat"].statuses) == 1
  end

  test "ignores losing channel fields, lists and statuses without rejecting the frame" do
    {:ok, runtime} = Runtime.new(config())
    uid = Identity.uid()
    owner = user(uid, runtime.boot)
    winning = %{"name" => "#arbitrated", "born_ms" => 10, "cid" => Identity.cid()}
    losing = %{"name" => "#arbitrated", "born_ms" => 20, "cid" => Identity.cid()}

    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => owner})
    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "channel.ensure", "channel" => winning})

    membership = %{"channel" => "#arbitrated", "join_id" => 1, "joined_ms" => 2}

    assert {:ok, runtime, _} =
             Runtime.apply_local_row(runtime, %{
               "kind" => "memberships.put",
               "uid" => uid,
               "home" => owner["home"],
               "rev" => 1,
               "entries" => [membership],
               "cause" => %{
                 "action" => "join",
                 "channel" => "#arbitrated",
                 "join_id" => 1,
                 "by" => %{"user" => uid},
                 "reason" => "join"
               }
             })

    field = %{
      "kind" => "channel.field",
      "channel" => losing,
      "field" => "topic",
      "value" => %{"text" => "losing", "setter" => "remote", "set_ms" => 3},
      "stamp" => [1, "root", runtime.boot],
      "setter" => %{"user" => uid}
    }

    list = %{
      "kind" => "channel.list",
      "channel" => losing,
      "mode" => "b",
      "mask" => "*!*@example.test",
      "present" => true,
      "set_by" => "remote",
      "set_ms" => 3,
      "stamp" => [2, "root", runtime.boot]
    }

    status = %{
      "kind" => "member.status",
      "channel" => losing,
      "uid" => uid,
      "join_id" => 1,
      "mode" => "o",
      "enabled" => true,
      "stamp" => [3, "root", runtime.boot],
      "setter" => %{"user" => uid}
    }

    assert {:ok, unchanged, []} = Runtime.apply_local_rows(runtime, [field, list, status])
    assert unchanged == runtime
    assert unchanged.channels["#arbitrated"].registers == %{}
    assert unchanged.channels["#arbitrated"].list_slots == %{}
    assert unchanged.channels["#arbitrated"].statuses == %{}

    missing_status = %{status | "channel" => %{"name" => "#missing", "born_ms" => 1, "cid" => Identity.cid()}}
    assert {:ok, ^unchanged, []} = Runtime.apply_local_row(unchanged, missing_status)
  end

  test "routes invite notices only for the current channel incarnation" do
    {:ok, runtime} = Runtime.new(config())
    uid = Identity.uid()
    owner = user(uid, runtime.boot)
    channel = %{"name" => "#invite", "born_ms" => 10, "cid" => Identity.cid()}

    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => owner})
    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "channel.ensure", "channel" => channel})

    notice = %{
      "kind" => "invite.notice",
      "invite_id" => Identity.nonce(),
      "target_uid" => uid,
      "inviter_uid" => Identity.uid(),
      "channel" => channel,
      "expires_ms" => 0
    }

    assert {:ok, ^runtime, [%{kind: :invite, origin: origin, row: ^notice}]} =
             Runtime.apply_local_row(runtime, notice)

    losing_notice = %{notice | "channel" => %{channel | "born_ms" => 20}}
    assert {:ok, ^runtime, []} = Runtime.apply_local_row(runtime, losing_notice)

    missing_notice = %{notice | "channel" => %{channel | "name" => "#missing"}}
    assert {:error, :missing_channel} = Runtime.apply_local_row(runtime, missing_notice)
    assert origin == %{"sid" => "root", "boot" => runtime.boot}
  end

  test "accepts an owner membership publication whose cause names a remote actor" do
    {:ok, runtime} = Runtime.new(config())
    owner_uid = Identity.uid()
    actor_uid = Identity.uid()
    owner = user(owner_uid, runtime.boot) |> Map.put("requested_nick", "Target")

    actor =
      user(actor_uid, runtime.boot)
      |> Map.put("requested_nick", "Operator")
      |> Map.put("home", %{"sid" => "leaf", "boot" => Identity.boot()})

    runtime = %{runtime | users: %{actor_uid => actor}}
    membership = %{"channel" => "#chat", "join_id" => 1, "joined_ms" => 2}

    row = %{
      "kind" => "memberships.put",
      "uid" => owner_uid,
      "home" => %{"sid" => runtime.sid, "boot" => runtime.boot},
      "rev" => 1,
      "entries" => [membership],
      "cause" => %{
        "action" => "kick",
        "channel" => "#chat",
        "join_id" => 1,
        "by" => %{"user" => actor_uid},
        "reason" => "remote operator"
      }
    }

    assert {:ok, runtime, _effects} =
             Runtime.apply_local_rows(runtime, [%{"kind" => "user.put", "user" => owner}, row], local_owner: true)

    frame = %{
      "t" => "state",
      "n" => 1,
      "origin" => %{"sid" => runtime.sid, "boot" => runtime.boot},
      "actor" => %{"server" => runtime.sid},
      "context" => %{"kind" => "live"},
      "changes" => [row]
    }

    assert {:ok, _runtime, _effects} = Runtime.apply_frame(runtime, frame)
  end

  test "forgets an unguarded channel when its last membership leaves" do
    {:ok, runtime} = Runtime.new(config())
    uid = Identity.uid()
    channel = %{"name" => "#transient", "born_ms" => 1, "cid" => Identity.cid()}
    owner = user(uid, runtime.boot)

    assert {:ok, runtime, _effects} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => owner})

    assert {:ok, runtime, _effects} =
             Runtime.apply_local_row(runtime, %{"kind" => "channel.ensure", "channel" => channel})

    membership = %{"channel" => "#transient", "join_id" => 1, "joined_ms" => 2}

    assert {:ok, runtime, _effects} =
             Runtime.apply_local_row(runtime, %{
               "kind" => "memberships.put",
               "uid" => uid,
               "home" => owner["home"],
               "rev" => 1,
               "entries" => [membership],
               "cause" => %{
                 "action" => "join",
                 "channel" => "#transient",
                 "join_id" => 1,
                 "by" => %{"user" => uid},
                 "reason" => "join"
               }
             })

    assert {:ok, runtime, effects} =
             Runtime.apply_local_row(runtime, %{
               "kind" => "memberships.put",
               "uid" => uid,
               "home" => owner["home"],
               "rev" => 2,
               "entries" => [],
               "cause" => %{
                 "action" => "part",
                 "channel" => "#transient",
                 "join_id" => 1,
                 "by" => %{"user" => uid},
                 "reason" => "part"
               }
             })

    assert runtime.channels == %{}
    assert Enum.any?(effects, &(&1.removed_channels == ["#transient"]))
  end

  test "retains a guarded channel when its last membership leaves" do
    {:ok, runtime} = Runtime.new(config())
    uid = Identity.uid()
    channel = %{"name" => "#guarded", "born_ms" => 1, "cid" => Identity.cid()}
    owner = user(uid, runtime.boot)

    policy =
      Policy.new(
        epoch: runtime.policy.epoch,
        objects: %{{"channel", "#guarded"} => %{"settings" => %{"guard" => true}}}
      )

    runtime = %{runtime | policy: policy}

    assert {:ok, runtime, _effects} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => owner})

    assert {:ok, runtime, _effects} =
             Runtime.apply_local_row(runtime, %{"kind" => "channel.ensure", "channel" => channel})

    membership = %{"channel" => "#guarded", "join_id" => 1, "joined_ms" => 2}

    assert {:ok, runtime, _effects} =
             Runtime.apply_local_row(runtime, %{
               "kind" => "memberships.put",
               "uid" => uid,
               "home" => owner["home"],
               "rev" => 1,
               "entries" => [membership],
               "cause" => %{
                 "action" => "join",
                 "channel" => "#guarded",
                 "join_id" => 1,
                 "by" => %{"user" => uid},
                 "reason" => "join"
               }
             })

    assert {:ok, runtime, effects} =
             Runtime.apply_local_row(runtime, %{
               "kind" => "memberships.put",
               "uid" => uid,
               "home" => owner["home"],
               "rev" => 2,
               "entries" => [],
               "cause" => %{
                 "action" => "part",
                 "channel" => "#guarded",
                 "join_id" => 1,
                 "by" => %{"user" => uid},
                 "reason" => "part"
               }
             })

    assert runtime.channels["#guarded"]
    assert Enum.any?(effects, &(&1.removed_channels == []))
  end

  test "a malformed frame leaves the previous runtime unchanged" do
    {:ok, runtime} = Runtime.new(config())
    origin = %{"sid" => runtime.sid, "boot" => runtime.boot}

    good = %{
      "kind" => "invite.notice",
      "invite_id" => Identity.nonce(),
      "target_uid" => Identity.uid(),
      "inviter_uid" => Identity.uid(),
      "channel" => %{"name" => "#chat", "born_ms" => 1, "cid" => Identity.cid()},
      "expires_ms" => 2
    }

    bad = Map.put(good, "unknown", true)

    frame = %{
      "t" => "state",
      "n" => 1,
      "origin" => origin,
      "actor" => %{"server" => runtime.sid},
      "context" => %{"kind" => "live"},
      "changes" => [good, bad]
    }

    assert {:error, _} = Runtime.apply_frame(runtime, frame)
    assert runtime.users == %{}
    assert runtime.channels == %{}
  end

  test "rejects a local origin carrying an unknown boot" do
    {:ok, runtime} = Runtime.new(config())
    fake_boot = Identity.boot()

    frame = %{
      "t" => "state",
      "n" => 1,
      "origin" => %{"sid" => runtime.sid, "boot" => fake_boot},
      "actor" => %{"server" => runtime.sid},
      "context" => %{"kind" => "live"},
      "changes" => [
        %{
          "kind" => "channel.ensure",
          "channel" => %{"name" => "#spoofed", "born_ms" => 1, "cid" => Identity.cid()}
        }
      ]
    }

    assert {:error, :invalid_origin_route} = Runtime.apply_frame(runtime, frame, source_sid: runtime.sid)
    assert runtime.channels == %{}
  end

  test "merge state accepts imported owner rows only while its marker is open" do
    {:ok, runtime} = Runtime.new(branching_config())
    leaf_boot = Identity.boot()

    topology = %{
      "kind" => "topology.add",
      "nodes" => [
        %{"sid" => "root", "boot" => runtime.boot, "name" => "root.example.test", "description" => ""},
        %{"sid" => "leaf", "boot" => leaf_boot, "name" => "leaf.example.test", "description" => ""}
      ],
      "edges" => [
        %{
          "id" => String.duplicate("c", 64),
          "a" => %{"sid" => "leaf", "boot" => leaf_boot},
          "b" => %{"sid" => "root", "boot" => runtime.boot},
          "ready_sides" => ["leaf", "root"]
        }
      ]
    }

    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, topology)
    merge_id = Identity.nonce()

    assert {:ok, runtime, _} =
             Runtime.apply_local_row(runtime, %{
               "kind" => "merge.begin",
               "id" => merge_id,
               "via" => %{"sid" => "leaf", "boot" => leaf_boot}
             })

    imported = user(Identity.uid(), leaf_boot)
    imported = %{imported | "home" => %{"sid" => "leaf", "boot" => leaf_boot}}

    frame = %{
      "t" => "state",
      "n" => 1,
      "origin" => %{"sid" => "root", "boot" => runtime.boot},
      "actor" => %{"server" => "root"},
      "context" => %{"kind" => "merge", "id" => merge_id},
      "changes" => [%{"kind" => "user.put", "user" => imported}]
    }

    assert {:ok, runtime, _} = Runtime.apply_frame(runtime, frame, source_sid: "root", snapshot: true)
    assert runtime.users[imported["uid"]]["home"]["sid"] == "leaf"

    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "merge.end", "id" => merge_id})
    assert {:error, :unknown_merge_context} = Runtime.apply_frame(runtime, frame, source_sid: "root", snapshot: true)
  end

  test "a topology split clears open merge contexts" do
    {:ok, runtime} = Runtime.new(branching_config())
    leaf_boot = Identity.boot()
    edge_id = String.duplicate("b", 64)

    topology = %{
      "kind" => "topology.add",
      "nodes" => [
        %{"sid" => "root", "boot" => runtime.boot, "name" => "root.example.test", "description" => ""},
        %{"sid" => "leaf", "boot" => leaf_boot, "name" => "leaf.example.test", "description" => ""}
      ],
      "edges" => [
        %{
          "id" => edge_id,
          "a" => %{"sid" => "leaf", "boot" => leaf_boot},
          "b" => %{"sid" => "root", "boot" => runtime.boot},
          "ready_sides" => ["leaf", "root"]
        }
      ]
    }

    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, topology)
    merge_id = Identity.nonce()

    assert {:ok, runtime, _} =
             Runtime.apply_local_row(runtime, %{
               "kind" => "merge.begin",
               "id" => merge_id,
               "via" => %{"sid" => "leaf", "boot" => leaf_boot}
             })

    assert MapSet.member?(runtime.merge_contexts, merge_id)

    assert {:ok, runtime, _} =
             Runtime.apply_local_row(runtime, %{
               "kind" => "topology.remove",
               "edge_id" => edge_id,
               "reporter" => "root",
               "reason" => "split"
             })

    refute MapSet.member?(runtime.merge_contexts, merge_id)
  end

  test "topology removal must be originated by the endpoint reporting the edge loss" do
    {:ok, runtime} = Runtime.new(branching_config())
    leaf_boot = Identity.boot()
    edge_id = String.duplicate("d", 64)

    topology = %{
      "kind" => "topology.add",
      "nodes" => [
        %{"sid" => "root", "boot" => runtime.boot, "name" => "root.example.test", "description" => ""},
        %{"sid" => "leaf", "boot" => leaf_boot, "name" => "leaf.example.test", "description" => ""}
      ],
      "edges" => [
        %{
          "id" => edge_id,
          "a" => %{"sid" => "leaf", "boot" => leaf_boot},
          "b" => %{"sid" => "root", "boot" => runtime.boot},
          "ready_sides" => ["leaf", "root"]
        }
      ]
    }

    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, topology)

    row = %{
      "kind" => "topology.remove",
      "edge_id" => edge_id,
      "reporter" => "leaf",
      "reason" => "link failure"
    }

    assert {:error, :invalid_edge_reporter} =
             Runtime.apply_frame(
               runtime,
               %{
                 "t" => "state",
                 "n" => 1,
                 "origin" => %{"sid" => "root", "boot" => runtime.boot},
                 "actor" => %{"server" => "root"},
                 "context" => %{"kind" => "live"},
                 "changes" => [row]
               },
               source_sid: "root"
             )
  end

  test "newer user revisions win and equal contradictory revisions fail" do
    {:ok, runtime} = Runtime.new(config())
    uid = Identity.uid()
    first = user(uid, runtime.boot)
    newer = %{first | "rev" => 2, "requested_nick" => "Other"}
    contradictory = %{newer | "realname" => "Different"}

    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => first})
    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => newer})
    assert runtime.users[uid]["requested_nick"] == "Other"

    assert {:error, :user_revision_conflict} =
             Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => contradictory})
  end

  test "duplicate live UIDs from another home cannot replace the original session" do
    {:ok, runtime} = Runtime.new(branching_config())
    leaf_boot = Identity.boot()

    topology = %{
      "kind" => "topology.add",
      "nodes" => [
        %{"sid" => "root", "boot" => runtime.boot, "name" => "root.example.test", "description" => ""},
        %{"sid" => "leaf", "boot" => leaf_boot, "name" => "leaf.example.test", "description" => ""}
      ],
      "edges" => [
        %{
          "id" => String.duplicate("c", 64),
          "a" => %{"sid" => "leaf", "boot" => leaf_boot},
          "b" => %{"sid" => "root", "boot" => runtime.boot},
          "ready_sides" => ["leaf", "root"]
        }
      ]
    }

    assert {:ok, runtime, _effects} = Runtime.apply_local_row(runtime, topology)

    uid = "AAAAAAAAAAAAAAAAAAAAAAAAAA"
    original = user(uid, runtime.boot)
    assert {:ok, runtime, _effects} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => original})

    duplicate = %{
      original
      | "home" => %{"sid" => "leaf", "boot" => leaf_boot},
        "rev" => 2,
        "requested_nick" => "Replacement"
    }

    frame = %{
      "t" => "state",
      "n" => 1,
      "origin" => %{"sid" => "leaf", "boot" => leaf_boot},
      "actor" => %{"server" => "leaf"},
      "context" => %{"kind" => "live"},
      "changes" => [%{"kind" => "user.put", "user" => duplicate}]
    }

    assert {:error, :uid_home_conflict} = Runtime.apply_frame(runtime, frame, source_sid: "leaf")
    assert runtime.users[uid]["requested_nick"] == "Rafael"
    assert runtime.users[uid]["home"] == %{"sid" => "root", "boot" => runtime.boot}
  end

  test "nickname claims converge for every arrival order and restore only retained claims" do
    {:ok, empty_runtime} = Runtime.new(config())
    first_uid = "AAAAAAAAAAAAAAAAAAAAAAAAAA"
    second_uid = "BAAAAAAAAAAAAAAAAAAAAAAAAA"
    third_uid = "CAAAAAAAAAAAAAAAAAAAAAAAAA"
    claimants = Enum.map([first_uid, second_uid, third_uid], &user(&1, empty_runtime.boot))

    permutations = [
      claimants,
      [Enum.at(claimants, 0), Enum.at(claimants, 2), Enum.at(claimants, 1)],
      [Enum.at(claimants, 1), Enum.at(claimants, 0), Enum.at(claimants, 2)],
      [Enum.at(claimants, 1), Enum.at(claimants, 2), Enum.at(claimants, 0)],
      [Enum.at(claimants, 2), Enum.at(claimants, 0), Enum.at(claimants, 1)],
      Enum.reverse(claimants)
    ]

    projections =
      Enum.map(permutations, fn order ->
        rows = Enum.map(order, &%{"kind" => "user.put", "user" => &1})
        assert {:ok, projected, _effects} = Runtime.apply_local_rows(empty_runtime, rows)
        Map.new(projected.users, fn {uid, projection} -> {uid, projection["effective_nick"]} end)
      end)

    assert Enum.uniq(projections) == [hd(projections)]
    assert hd(projections)[first_uid] == "Rafael"
    assert hd(projections)[second_uid] == State.fallback_nickname(second_uid)
    assert hd(projections)[third_uid] == State.fallback_nickname(third_uid)

    [winner, retained_claimant | _] = claimants
    runtime = empty_runtime

    assert {:ok, runtime, _effects} =
             Runtime.apply_local_rows(
               runtime,
               Enum.map([winner, retained_claimant], &%{"kind" => "user.put", "user" => &1})
             )

    quit = %{
      "kind" => "user.quit",
      "uid" => winner["uid"],
      "home" => winner["home"],
      "rev" => winner["rev"],
      "reason" => "disconnected",
      "action" => "quit",
      "by" => %{"server" => "root"}
    }

    assert {:ok, runtime, _effects} = Runtime.apply_local_row(runtime, quit)
    assert runtime.users[retained_claimant["uid"]]["effective_nick"] == "Rafael"

    runtime = empty_runtime
    changed_claimant = %{retained_claimant | "rev" => 2, "requested_nick" => "Other"}

    assert {:ok, runtime, _effects} =
             Runtime.apply_local_rows(runtime, [
               %{"kind" => "user.put", "user" => winner},
               %{"kind" => "user.put", "user" => changed_claimant}
             ])

    assert {:ok, runtime, _effects} = Runtime.apply_local_row(runtime, quit)
    assert runtime.users[retained_claimant["uid"]]["effective_nick"] == "Other"
  end

  test "policy deletion invalidates projected bindings and registered mode" do
    epoch = Identity.nonce()
    account_id = Identity.uid()

    policy =
      Policy.new(epoch: epoch, revision: 1, objects: %{{"account", account_id} => account(account_id)}, ready?: true)

    {:ok, runtime} = Runtime.new(config())
    runtime = %{runtime | services_authority: runtime.sid, policy: policy}
    uid = Identity.uid()

    projected =
      user(uid, runtime.boot)
      |> Map.put("binding", %{"account_id" => account_id, "auth_epoch" => 1, "policy_epoch" => epoch})

    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => projected})

    change = %{
      "kind" => "policy.change",
      "epoch" => epoch,
      "revision" => 2,
      "changes" => [%{"entity" => "account", "key" => account_id, "value" => nil}]
    }

    assert {:ok, runtime, effects} = Runtime.apply_local_row(runtime, change)
    assert runtime.users[uid]["binding"] == nil
    assert runtime.users[uid]["modes"] == []
    assert Enum.any?(effects, &(&1.kind == :binding_invalidated and &1.uid == uid))
  end

  test "a policy refresh restores the registered mode for a still-valid binding" do
    epoch = Identity.nonce()
    account_id = Identity.uid()
    public_account = account(account_id) |> Map.put("aliases", ["Rafael"])

    policy = Policy.new(epoch: epoch, revision: 1, objects: %{{"account", account_id} => public_account}, ready?: true)

    {:ok, runtime} = Runtime.new(config())
    runtime = %{runtime | services_authority: runtime.sid, policy: policy}
    uid = Identity.uid()

    projected =
      user(uid, runtime.boot)
      |> Map.put("binding", %{"account_id" => account_id, "auth_epoch" => 1, "policy_epoch" => epoch})

    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => projected})

    refreshed_account = put_in(public_account, ["settings", "no_greet"], true)

    change = %{
      "kind" => "policy.change",
      "epoch" => epoch,
      "revision" => 2,
      "changes" => [%{"entity" => "account", "key" => account_id, "value" => refreshed_account}]
    }

    assert {:ok, runtime, effects} = Runtime.apply_local_row(runtime, change)
    assert "r" in runtime.users[uid]["modes"]
    assert Enum.any?(effects, &(&1.kind == :binding_mode and &1.uid == uid and &1.enabled))
  end

  test "removing a nick alias preserves account authentication and clears only registered mode" do
    epoch = Identity.nonce()
    account_id = Identity.uid()
    account_before = account(account_id) |> Map.put("aliases", ["Rafael"])

    policy = Policy.new(epoch: epoch, revision: 1, objects: %{{"account", account_id} => account_before}, ready?: true)

    {:ok, runtime} = Runtime.new(config())
    runtime = %{runtime | services_authority: runtime.sid, policy: policy}
    uid = Identity.uid()
    binding = %{"account_id" => account_id, "auth_epoch" => 1, "policy_epoch" => epoch}

    projected = user(uid, runtime.boot) |> Map.put("binding", binding)
    assert {:ok, runtime, _effects} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => projected})

    account_refreshed = put_in(account_before, ["settings", "no_greet"], true)

    refresh = %{
      "kind" => "policy.change",
      "epoch" => epoch,
      "revision" => 2,
      "changes" => [%{"entity" => "account", "key" => account_id, "value" => account_refreshed}]
    }

    assert {:ok, runtime, _effects} = Runtime.apply_local_row(runtime, refresh)
    assert "r" in runtime.users[uid]["modes"]

    account_after = Map.put(account_refreshed, "aliases", ["account"])

    change = %{
      "kind" => "policy.change",
      "epoch" => epoch,
      "revision" => 3,
      "changes" => [%{"entity" => "account", "key" => account_id, "value" => account_after}]
    }

    assert {:ok, runtime, effects} = Runtime.apply_local_row(runtime, change)
    assert runtime.users[uid]["binding"] == binding
    assert runtime.users[uid]["modes"] == []
    assert Enum.any?(effects, &(&1.kind == :binding_mode and &1.uid == uid and not &1.enabled))
    refute Enum.any?(effects, &(&1.kind == :binding_invalidated and &1.uid == uid))
  end

  test "a complete snapshot prunes stale topology, users and global channels" do
    {:ok, runtime} = Runtime.new(branching_config())
    child_boot = Identity.boot()

    edge = %{
      "id" => String.duplicate("a", 64),
      "a" => %{"sid" => "leaf", "boot" => child_boot},
      "b" => %{"sid" => "root", "boot" => runtime.boot},
      "ready_sides" => ["leaf", "root"]
    }

    topology = %{
      "kind" => "topology.add",
      "nodes" => [
        %{"sid" => "root", "boot" => runtime.boot, "name" => "root.example.test", "description" => ""},
        %{"sid" => "leaf", "boot" => child_boot, "name" => "leaf.example.test", "description" => ""}
      ],
      "edges" => [edge]
    }

    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, topology)

    uid = Identity.uid()

    assert {:ok, runtime, _} =
             Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => user(uid, runtime.boot)})

    old_channel = %{"name" => "#old", "born_ms" => 1, "cid" => Identity.cid()}
    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "channel.ensure", "channel" => old_channel})

    replacement = %{
      "kind" => "topology.add",
      "nodes" => [%{"sid" => "root", "boot" => runtime.boot, "name" => "root.example.test", "description" => ""}],
      "edges" => []
    }

    assert {:ok, next, _} =
             Runtime.apply_snapshot_rows(
               runtime,
               [replacement],
               %{"sid" => "root", "boot" => runtime.boot},
               %{"kind" => "live"},
               source_sid: "root"
             )

    assert next.nodes == %{
             "root" => %{"sid" => "root", "boot" => runtime.boot, "name" => "root.example.test", "description" => ""}
           }

    assert next.edges == %{}
    assert next.users == %{}
    assert next.channels == %{}
  end

  test "preserves the local physical edge while importing a remote snapshot" do
    {:ok, runtime} = Runtime.new(branching_config())
    child_boot = Identity.boot()

    edge = %{
      "id" => String.duplicate("e", 64),
      "a" => %{"sid" => "leaf", "boot" => child_boot},
      "b" => %{"sid" => "root", "boot" => runtime.boot},
      "ready_sides" => ["leaf", "root"]
    }

    topology = %{
      "kind" => "topology.add",
      "nodes" => [
        %{"sid" => "root", "boot" => runtime.boot, "name" => "root.example.test", "description" => ""},
        %{"sid" => "leaf", "boot" => child_boot, "name" => "leaf.example.test", "description" => ""}
      ],
      "edges" => [edge]
    }

    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, topology)

    replacement = %{
      "kind" => "topology.add",
      "nodes" => [%{"sid" => "root", "boot" => runtime.boot, "name" => "root.example.test", "description" => ""}],
      "edges" => []
    }

    assert {:ok, next, _} =
             Runtime.apply_snapshot_rows(
               runtime,
               [replacement],
               %{"sid" => "root", "boot" => runtime.boot},
               %{"kind" => "live"},
               source_sid: "root",
               preserve_local_edges: true
             )

    assert next.edges[edge["id"]].ready_sides == ["leaf", "root"]
    assert next.nodes["leaf"]["boot"] == child_boot
    assert MapSet.equal?(next.reachable_sids, MapSet.new(["leaf", "root"]))
  end

  test "merges a remote snapshot without dropping a sibling branch" do
    leaf_boot = Identity.boot()
    branch_boot = Identity.boot()
    branch_leaf_boot = Identity.boot()

    config = [
      s2s: [
        server_id: "root",
        roster: [
          [sid: "root", name: "root.example.test", parent: nil],
          [sid: "leaf", name: "leaf.example.test", parent: "root"],
          [sid: "branch", name: "branch.example.test", parent: "root"],
          [sid: "branch-leaf", name: "branch-leaf.example.test", parent: "branch"]
        ],
        policy_epoch: Identity.nonce()
      ],
      settings: [case_mapping: :ascii]
    ]

    {:ok, runtime} = Runtime.new(config)

    topology = %{
      "kind" => "topology.add",
      "nodes" => [
        %{"sid" => "root", "boot" => runtime.boot, "name" => "root.example.test", "description" => ""},
        %{"sid" => "leaf", "boot" => leaf_boot, "name" => "leaf.example.test", "description" => ""},
        %{"sid" => "branch", "boot" => branch_boot, "name" => "branch.example.test", "description" => ""},
        %{
          "sid" => "branch-leaf",
          "boot" => branch_leaf_boot,
          "name" => "branch-leaf.example.test",
          "description" => ""
        }
      ],
      "edges" => [
        %{
          "id" => String.duplicate("a", 64),
          "a" => %{"sid" => "leaf", "boot" => leaf_boot},
          "b" => %{"sid" => "root", "boot" => runtime.boot},
          "ready_sides" => ["leaf", "root"]
        },
        %{
          "id" => String.duplicate("b", 64),
          "a" => %{"sid" => "branch", "boot" => branch_boot},
          "b" => %{"sid" => "root", "boot" => runtime.boot},
          "ready_sides" => ["branch", "root"]
        },
        %{
          "id" => String.duplicate("c", 64),
          "a" => %{"sid" => "branch", "boot" => branch_boot},
          "b" => %{"sid" => "branch-leaf", "boot" => branch_leaf_boot},
          "ready_sides" => ["branch", "branch-leaf"]
        }
      ]
    }

    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, topology)

    remote_view = %{
      "kind" => "topology.add",
      "nodes" => [
        %{"sid" => "root", "boot" => runtime.boot, "name" => "root.example.test", "description" => ""},
        %{"sid" => "leaf", "boot" => leaf_boot, "name" => "leaf.example.test", "description" => ""}
      ],
      "edges" => [topology["edges"] |> hd()]
    }

    assert {:ok, next, _} =
             Runtime.apply_snapshot_rows(
               runtime,
               [remote_view],
               %{"sid" => "root", "boot" => runtime.boot},
               %{"kind" => "live"},
               source_sid: "root",
               preserve_local_edges: true
             )

    assert map_size(next.edges) == 3
    assert MapSet.equal?(next.reachable_sids, MapSet.new(["branch", "branch-leaf", "leaf", "root"]))
  end

  test "unions readiness observed by concurrent topology publications" do
    {:ok, runtime} = Runtime.new(branching_config())
    child_boot = Identity.boot()
    edge_id = String.duplicate("f", 64)

    topology = %{
      "kind" => "topology.add",
      "nodes" => [
        %{"sid" => "root", "boot" => runtime.boot, "name" => "root.example.test", "description" => ""},
        %{"sid" => "leaf", "boot" => child_boot, "name" => "leaf.example.test", "description" => ""}
      ],
      "edges" => [
        %{
          "id" => edge_id,
          "a" => %{"sid" => "leaf", "boot" => child_boot},
          "b" => %{"sid" => "root", "boot" => runtime.boot},
          "ready_sides" => ["root"]
        }
      ]
    }

    assert {:ok, runtime, _} = Runtime.apply_local_row(runtime, topology)

    incoming = %{
      "t" => "state",
      "n" => 1,
      "origin" => %{"sid" => "leaf", "boot" => child_boot},
      "actor" => %{"server" => "leaf"},
      "context" => %{"kind" => "live"},
      "changes" => [
        %{
          "kind" => "topology.add",
          "nodes" => topology["nodes"],
          "edges" => [Map.put(topology["edges"] |> hd(), "ready_sides", ["leaf"])]
        }
      ]
    }

    assert {:ok, next, _} = Runtime.apply_frame(runtime, incoming, source_sid: "leaf")
    assert next.edges[edge_id].ready_sides == ["leaf", "root"]
    assert MapSet.equal?(next.reachable_sids, MapSet.new(["leaf", "root"]))
  end
end
