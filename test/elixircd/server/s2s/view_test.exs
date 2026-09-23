defmodule ElixIRCd.Server.S2S.ViewTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Policy
  alias ElixIRCd.Server.S2S.Runtime
  alias ElixIRCd.Server.S2S.View

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

  defp runtime(guard?, ready?, reachable?) do
    {:ok, runtime} = Runtime.new(config())

    policy =
      Policy.new(
        epoch: runtime.policy.epoch,
        revision: 1,
        ready?: ready?,
        objects: if(guard?, do: %{{"channel", "#guarded"} => %{"settings" => %{"guard" => true}}}, else: %{})
      )

    channel = %{
      ref: %{"name" => "#guarded", "born_ms" => 1_700_000_000_000, "cid" => Identity.cid()},
      registers: %{},
      list_slots: %{},
      statuses: %{}
    }

    %{
      runtime
      | services_authority: "root",
        reachable_sids: if(reachable?, do: MapSet.new(["root"]), else: MapSet.new()),
        policy: policy,
        channels: %{"#guarded" => channel}
    }
  end

  test "derives ChanServ from ready authority state without creating a persisted user" do
    runtime = runtime(true, true, true)

    assert {:ok, service} = View.chanserv_user(runtime)
    assert service.uid == "service:ChanServ"
    assert service.nick == "ChanServ"
    assert service.pid == nil
    assert service.ident == "service"

    assert {:ok, service, membership} = View.chanserv_membership(runtime, "#guarded")
    assert membership.uid == service.uid
    assert membership.user_pid == nil
    assert membership.join_id == nil

    assert [{"service:ChanServ", ^service, ^membership}] =
             View.channel_members_with_services(runtime, runtime.channels["#guarded"])
  end

  test "does not derive ChanServ when policy is not ready or authority is unreachable" do
    unreachable = %{runtime(true, true, true) | services_authority: "leaf"}

    refute View.services_ready?(runtime(true, false, true))
    refute View.services_ready?(unreachable)
    assert {:error, :service_unavailable} = View.chanserv_user(runtime(true, false, true))

    assert View.channel_members_with_services(
             unreachable,
             unreachable.channels["#guarded"]
           ) == []
  end

  test "only guarded channels expose the derived service membership" do
    runtime = runtime(false, true, true)

    assert View.channel_members_with_services(runtime, runtime.channels["#guarded"]) == []
    assert View.guarded_service_channels(runtime, nil) == []
    assert {:error, :guard_disabled} = View.chanserv_membership(runtime, "#guarded")
  end

  test "never derives global ChanServ membership for a local ampersand channel" do
    runtime = runtime(true, true, true)
    local_channel = %{runtime.channels["#guarded"] | ref: %{runtime.channels["#guarded"].ref | "name" => "&local"}}

    runtime = %{
      runtime
      | channels: %{"&local" => local_channel},
        policy: %{runtime.policy | objects: %{{"channel", "&local"} => %{"settings" => %{"guard" => true}}}}
    }

    assert {:error, :local_channel} = View.chanserv_membership(runtime, "&local")
    assert View.guarded_service_channels(runtime, nil) == []
  end

  test "filters guarded secret and private channels for non-members" do
    runtime = runtime(true, true, true)
    channel = runtime.channels["#guarded"]

    secret = %{channel | registers: %{"mode:s" => %{value: true}}}
    private = %{channel | registers: %{"mode:p" => %{value: true}}}

    runtime = %{
      runtime
      | channels: %{
          "#secret" => %{secret | ref: %{secret.ref | "name" => "#secret"}},
          "#private" => %{private | ref: %{private.ref | "name" => "#private"}}
        }
    }

    policy =
      %{
        runtime.policy
        | objects: %{
            {"channel", "#secret"} => %{"settings" => %{"guard" => true}},
            {"channel", "#private"} => %{"settings" => %{"guard" => true}}
          }
      }

    runtime = %{runtime | policy: policy}

    assert Enum.map(View.guarded_service_channels(runtime, "missing-user"), & &1.name) == []
  end
end
