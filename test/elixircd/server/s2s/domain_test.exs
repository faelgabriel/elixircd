defmodule ElixIRCd.Server.S2S.DomainTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Server.S2S.Domain
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Output
  alias ElixIRCd.Server.S2S.Runtime
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.UserChannels

  defp config(boot) do
    [
      s2s: [
        enabled: true,
        server_id: "local",
        server_name: "local.example.test",
        services_authority: nil,
        boot: boot,
        roster: [[sid: "local", name: "local.example.test", parent: nil]],
        policy_epoch: Identity.nonce()
      ],
      settings: [case_mapping: :ascii]
    ]
  end

  defp guards(overrides) do
    Map.merge(
      %{
        "actor_uid" => nil,
        "actor_user_rev" => nil,
        "actor_join_id" => nil,
        "target_user_rev" => 1,
        "target_join_id" => nil,
        "channel" => nil,
        "policy_epoch" => nil,
        "policy_revision" => nil
      },
      overrides
    )
  end

  defp runtime(boot) do
    {:ok, runtime} = Runtime.new(config(boot))
    {:ok, runtime} = Runtime.bootstrap(runtime)
    runtime
  end

  defp channel_ref(channel) do
    %{"name" => channel.name, "born_ms" => channel.born_ms, "cid" => channel.cid}
  end

  test "owner executes a guarded forced part and publishes the new membership intent" do
    boot = Identity.boot()
    user = insert(:user, home_sid: "local", home_boot: boot)
    channel = insert(:channel, name: "#remote-part", born_ms: 10, cid: Identity.cid())
    insert(:user_channel, user: user, channel: channel, join_id: 7)

    frame = %{
      "method" => "user_action",
      "actor" => %{"user" => user.uid},
      "guards" =>
        guards(%{
          "actor_uid" => user.uid,
          "target_join_id" => 7,
          "channel" => channel_ref(channel),
          "policy_epoch" => Identity.nonce(),
          "policy_revision" => 99
        }),
      "args" => %{
        "action" => "part",
        "target_uid" => user.uid,
        "value" => %{"channel" => channel_ref(channel), "join_id" => 7},
        "reason" => "owner request"
      }
    }

    assert {:ok, %{"accepted" => true, "owner_rev" => 1}, effects} =
             Domain.execute(frame, runtime(boot), %{local_sid: "local", services_authority: nil, operator_role: nil})

    assert {:error, :user_channel_not_found} =
             Memento.transaction!(fn -> UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name) end)

    assert Enum.any?(effects, &(&1.kind == :s2s_memberships))
  end

  test "a delayed recovery kill is stale after the target nick revision changes" do
    boot = Identity.boot()
    parent = self()

    receiver =
      spawn(fn ->
        receive do
          message -> send(parent, {:target_effect, message})
        end
      end)

    on_exit(fn -> if Process.alive?(receiver), do: Process.exit(receiver, :kill) end)

    user =
      insert(:user,
        pid: receiver,
        nick: "Target",
        registered: true,
        home_sid: "local",
        home_boot: boot,
        owner_rev: 1
      )

    stale_revision = user.owner_rev
    updated = Memento.transaction!(fn -> Users.update(user, %{nick: "Replacement"}) end)
    runtime = runtime(boot)

    frame = %{
      "method" => "user_action",
      "actor" => %{"service" => "NickServ"},
      "guards" => guards(%{"target_user_rev" => stale_revision}),
      "args" => %{
        "action" => "kill",
        "target_uid" => user.uid,
        "value" => nil,
        "reason" => "NickServ RECOVER"
      }
    }

    assert updated.owner_rev == stale_revision + 1

    assert {:error, "STALE", "target user revision changed", []} =
             Domain.execute(frame, runtime, %{local_sid: "local", services_authority: nil, operator_role: nil})

    assert {:ok, current_user} = Memento.transaction!(fn -> Users.get_by_uid(user.uid) end)
    assert current_user.nick == "Replacement"
    refute_receive {:target_effect, _message}
  end

  test "owner stores one expiring invite and returns one network notice row" do
    boot = Identity.boot()
    inviter = insert(:user, home_sid: "local", home_boot: boot)
    target = insert(:user, home_sid: "local", home_boot: boot)
    channel = insert(:channel, name: "#remote-invite", born_ms: 11, cid: Identity.cid())
    insert(:user_channel, user: inviter, channel: channel, join_id: 3, modes: [:o])

    frame = %{
      "method" => "invite",
      "origin" => %{"sid" => "local", "boot" => boot},
      "actor" => %{"user" => inviter.uid},
      "guards" => guards(%{"actor_uid" => inviter.uid, "target_user_rev" => target.owner_rev}),
      "args" => %{
        "invite_id" => Identity.nonce(),
        "inviter_uid" => inviter.uid,
        "target_uid" => target.uid,
        "channel" => channel_ref(channel),
        "expires_ms" => System.system_time(:millisecond) + 60_000
      }
    }

    assert {:ok, %{"accepted" => true}, effects} =
             Domain.execute(frame, runtime(boot), %{local_sid: "local", services_authority: nil, operator_role: nil})

    assert {:ok, invite} =
             Memento.transaction!(fn -> ChannelInvites.get_by_user_pid_and_channel_name(target.pid, channel.name) end)

    assert invite.invite_id == frame["args"]["invite_id"]
    assert invite.expires_ms == frame["args"]["expires_ms"]
    assert Enum.any?(effects, &(&1.kind == :c2s_message))
    assert Enum.any?(effects, &(&1.kind == :s2s_rows and hd(&1.rows)["kind"] == "invite.notice"))
  end

  test "deferred owner mutation keeps committed output until the owner drain completes" do
    boot = Identity.boot()
    user = insert(:user, home_sid: "local", home_boot: boot)
    channel = insert(:channel, name: "#deferred-part", born_ms: 12, cid: Identity.cid())
    insert(:user_channel, user: user, channel: channel, join_id: 8)

    frame = %{
      "method" => "user_action",
      "origin" => %{"sid" => "local", "boot" => boot},
      "actor" => %{"user" => user.uid},
      "guards" =>
        guards(%{
          "actor_uid" => user.uid,
          "target_join_id" => 8,
          "channel" => channel_ref(channel)
        }),
      "args" => %{
        "action" => "part",
        "target_uid" => user.uid,
        "value" => %{"channel" => channel_ref(channel), "join_id" => 8},
        "reason" => "deferred owner request"
      }
    }

    assert {:ok, %{"accepted" => true}, group} =
             Domain.execute_deferred(frame, runtime(boot), %{
               local_sid: "local",
               services_authority: nil,
               operator_role: nil,
               origin_sid: "local",
               origin_boot: boot
             })

    assert is_map(group)
    assert Enum.any?(Output.pending_groups(), &(&1.sequence == group.sequence))

    assert {:error, :simulated_writer_crash} =
             Output.drain_pending(group, fn _intent -> {:error, :simulated_writer_crash} end)

    assert Enum.any?(Output.pending_groups(), &(&1.sequence == group.sequence))
    assert {:ok, 1} = Output.fence_pending()
  end

  test "rejects an owner action whose actor origin does not own the actor" do
    boot = Identity.boot()
    user = insert(:user, home_sid: "local", home_boot: boot)

    frame = %{
      "method" => "user_action",
      "actor" => %{"user" => user.uid},
      "guards" => guards(%{"actor_uid" => user.uid, "target_user_rev" => user.owner_rev || 1}),
      "args" => %{
        "action" => "nick",
        "target_uid" => user.uid,
        "value" => %{"nick" => "origin-mismatch"},
        "reason" => "invalid origin"
      }
    }

    assert {:error, "REJECTED", "actor origin does not own actor", []} =
             Domain.execute(
               frame,
               runtime(boot),
               %{
                 local_sid: "local",
                 services_authority: nil,
                 origin_sid: "other",
                 origin_boot: Identity.boot(),
                 operator_role: nil
               }
             )

    assert {:ok, ^user} = Memento.transaction!(fn -> ElixIRCd.Repositories.Users.get_by_uid(user.uid) end)
  end
end
