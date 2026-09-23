defmodule ElixIRCd.Server.S2S.DeliveryTest do
  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Server.S2S.Delivery
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Runtime

  defp config do
    [
      s2s: [
        server_id: "root",
        network_id: "delivery-test",
        roster: [
          [sid: "root", name: "root.example.test", parent: nil],
          [sid: "leaf", name: "leaf.example.test", parent: "root"]
        ]
      ],
      settings: [case_mapping: :ascii]
    ]
  end

  defp user(uid, home, boot, nick, modes \\ []) do
    %{
      "uid" => uid,
      "home" => %{"sid" => home, "boot" => boot},
      "rev" => 1,
      "requested_nick" => nick,
      "signon_ms" => 1,
      "ident" => "ident",
      "realhost" => "real.example",
      "displayhost" => "display.example",
      "address" => "192.0.2.1",
      "secure_client" => true,
      "client_certfp" => nil,
      "modes" => modes,
      "oper_role" => nil,
      "away" => nil,
      "realname" => "User",
      "binding" => nil
    }
  end

  defp frame(runtime, uid, target) do
    %{
      "t" => "message",
      "n" => 1,
      "origin" => %{"sid" => "root", "boot" => runtime.boot},
      "actor" => %{"user" => uid},
      "message_id" => Identity.nonce(),
      "sent_ms" => 1,
      "target" => target,
      "command" => "PRIVMSG",
      "text" => "hello",
      "tags" => %{},
      "request_id" => nil
    }
  end

  test "private messages resolve to the current UID home" do
    {:ok, runtime} = Runtime.new(config())
    sender_uid = Identity.uid()
    target_uid = Identity.uid()
    sender = user(sender_uid, "root", runtime.boot, "sender")
    target_boot = Identity.boot()
    target = user(target_uid, "leaf", target_boot, "target")
    {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => sender})

    {:ok, runtime} =
      Runtime.learn_node(runtime, %{"sid" => "leaf", "boot" => target_boot, "name" => "leaf.example.test"})

    {:ok, runtime, _} =
      Runtime.apply_snapshot_rows(runtime, [%{"kind" => "user.put", "user" => target}], %{
        "sid" => "leaf",
        "boot" => target_boot
      })

    assert {:ok, ["leaf"]} =
             Delivery.destination_sids(runtime, frame(runtime, sender_uid, %{"user" => target_uid}))

    assert {:ok, message} = Delivery.render(frame(runtime, sender_uid, %{"user" => target_uid}), runtime)
    assert message.prefix == "sender!ident@display.example"
    assert message.params == ["target"]
  end

  test "rejects a service actor when no explicit services authority is configured" do
    {:ok, runtime} = Runtime.new(config())
    actor_uid = Identity.uid()
    target_uid = Identity.uid()
    actor = user(actor_uid, "root", runtime.boot, "actor")
    target = user(target_uid, "root", runtime.boot, "target")

    {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => actor})
    {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => target})

    service_frame =
      frame(runtime, actor_uid, %{"user" => target_uid})
      |> Map.put("actor", %{"service" => "NickServ"})

    assert {:error, :service_actor_not_authoritative} = Delivery.destination_sids(runtime, service_frame)
  end

  test "returns the existing registered-only error for a remote private delivery" do
    boot = Identity.boot()
    runtime_config = put_in(config(), [:s2s, :boot], boot)
    actor_uid = Identity.uid()
    target_uid = Identity.uid()

    insert(:user, uid: actor_uid, nick: "Sender", home_sid: "root", home_boot: boot, modes: [])
    insert(:user, uid: target_uid, nick: "Target", home_sid: "root", home_boot: boot, modes: [:R])

    {:ok, runtime} = Runtime.new(runtime_config)
    {:ok, runtime} = Runtime.bootstrap(runtime)

    message = frame(runtime, actor_uid, %{"user" => target_uid}) |> Map.put("request_id", Identity.nonce())

    assert {:error, {:message_rejected, [%{"command" => "477", "source" => %{"server" => "root"}}]}} =
             Delivery.deliver_local(runtime, message)
  end

  test "channel fanout returns one home per eligible branch and honors status" do
    {:ok, runtime} = Runtime.new(config())
    sender_uid = Identity.uid()
    root_uid = Identity.uid()
    leaf_uid = Identity.uid()
    channel = %{"name" => "#chat", "born_ms" => 1, "cid" => Identity.cid()}
    sender = user(sender_uid, "root", runtime.boot, "sender")
    root_user = user(root_uid, "root", runtime.boot, "root-user")
    leaf_boot = Identity.boot()
    leaf_user = user(leaf_uid, "leaf", leaf_boot, "leaf-user")

    {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => sender})
    {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => root_user})
    {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "channel.ensure", "channel" => channel})

    cause = %{
      "action" => "join",
      "channel" => "#chat",
      "join_id" => 1,
      "by" => %{"user" => sender_uid},
      "reason" => "join"
    }

    runtime =
      Enum.reduce([{sender_uid, "root"}, {root_uid, "root"}], runtime, fn {uid, home}, current ->
        {:ok, next, _} =
          Runtime.apply_local_row(current, %{
            "kind" => "memberships.put",
            "uid" => uid,
            "home" => %{"sid" => home, "boot" => if(home == "root", do: current.boot, else: leaf_user["home"]["boot"])},
            "rev" => 1,
            "entries" => [%{"channel" => "#chat", "join_id" => 1, "joined_ms" => 2}],
            "cause" => cause
          })

        next
      end)

    {:ok, runtime} = Runtime.learn_node(runtime, %{"sid" => "leaf", "boot" => leaf_boot, "name" => "leaf.example.test"})

    leaf_membership = %{
      "kind" => "memberships.put",
      "uid" => leaf_uid,
      "home" => leaf_user["home"],
      "rev" => 1,
      "entries" => [%{"channel" => "#chat", "join_id" => 1, "joined_ms" => 2}],
      "cause" => cause
    }

    {:ok, runtime, _} =
      Runtime.apply_snapshot_rows(runtime, [%{"kind" => "user.put", "user" => leaf_user}, leaf_membership], %{
        "sid" => "leaf",
        "boot" => leaf_boot
      })

    message = frame(runtime, sender_uid, %{"channel" => channel, "minimum_status" => nil})
    assert {:ok, homes} = Delivery.destination_sids(runtime, message, "root")
    assert homes == ["leaf"]
  end

  test "audience fanout honors wallops, operator and snomask modes" do
    {:ok, runtime} = Runtime.new(config())
    actor_uid = Identity.uid()
    wallops_uid = Identity.uid()
    operator_uid = Identity.uid()
    snomask_uid = Identity.uid()
    ordinary_uid = Identity.uid()
    leaf_boot = Identity.boot()

    actor = user(actor_uid, "root", runtime.boot, "actor", ["o"])
    wallops = user(wallops_uid, "root", runtime.boot, "wallops", ["w"])
    operator = user(operator_uid, "leaf", leaf_boot, "operator", ["o"])
    snomask = user(snomask_uid, "leaf", leaf_boot, "snomask", ["s"])
    ordinary = user(ordinary_uid, "leaf", leaf_boot, "ordinary")

    {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => actor})
    {:ok, runtime, _} = Runtime.apply_local_row(runtime, %{"kind" => "user.put", "user" => wallops})

    {:ok, runtime} = Runtime.learn_node(runtime, %{"sid" => "leaf", "boot" => leaf_boot, "name" => "leaf.example.test"})

    {:ok, runtime, _} =
      Runtime.apply_snapshot_rows(
        runtime,
        Enum.map([operator, snomask, ordinary], &%{"kind" => "user.put", "user" => &1}),
        %{"sid" => "leaf", "boot" => leaf_boot}
      )

    wallops_frame = frame(runtime, actor_uid, %{"audience" => "wallops", "mask" => nil})
    operators_frame = frame(runtime, actor_uid, %{"audience" => "operators", "mask" => nil})
    snomask_frame = frame(runtime, actor_uid, %{"audience" => "snomask", "mask" => "kills"})

    assert {:ok, ["root"]} = Delivery.destination_sids(runtime, wallops_frame)
    assert {:ok, ["leaf", "root"]} = Delivery.destination_sids(runtime, operators_frame)
    assert {:ok, ["leaf"]} = Delivery.destination_sids(runtime, snomask_frame)
  end

  test "local channel delivery drops a wrong incarnation" do
    boot = Identity.boot()
    runtime_config = put_in(config(), [:s2s, :boot], boot)
    actor_uid = Identity.uid()
    recipient_uid = Identity.uid()
    cid = Identity.cid()

    insert(:user, uid: actor_uid, pid: self(), nick: "Sender", home_sid: "root", home_boot: boot, modes: [:o])
    channel = insert(:channel, name: "#chat", born_ms: 10, cid: cid)
    recipient = insert(:user, uid: recipient_uid, pid: self(), nick: "Target", home_sid: "root", home_boot: boot)
    insert(:user_channel, user: recipient, channel: channel)

    {:ok, runtime} = Runtime.new(runtime_config)
    {:ok, runtime} = Runtime.bootstrap(runtime)

    stale_ref = %{"name" => channel.name, "born_ms" => 9, "cid" => Identity.cid()}
    stale_frame = frame(runtime, actor_uid, %{"channel" => stale_ref, "minimum_status" => nil})

    assert :ok = Delivery.deliver_local(runtime, stale_frame)
    refute_receive {:broadcast, _wire}, 50

    current_frame =
      frame(runtime, actor_uid, %{
        "channel" => %{"name" => channel.name, "born_ms" => 10, "cid" => cid},
        "minimum_status" => nil
      })

    assert :ok = Delivery.deliver_local(runtime, current_frame)
    assert_receive {:broadcast, _wire}, 500
  end
end
