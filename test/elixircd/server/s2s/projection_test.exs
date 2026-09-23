defmodule ElixIRCd.Server.S2S.ProjectionTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Policy
  alias ElixIRCd.Server.S2S.Projection

  test "publishes a binding with the stable account and policy epochs" do
    account_id = Identity.uid()
    policy_epoch = Identity.nonce()
    registered_nick = insert(:registered_nick, nickname: "Alice", account_id: account_id)

    user =
      insert(:user,
        nick: "Alice",
        identified_as: "Alice",
        sasl_authenticated: true,
        home_sid: "root"
      )

    assert {:ok, projection} = Projection.user(user, user.home_boot, sid: "root", policy_epoch: policy_epoch)

    assert projection["binding"] == %{
             "account_id" => registered_nick.account_id,
             "auth_epoch" => registered_nick.auth_epoch,
             "policy_epoch" => policy_epoch
           }
  end

  test "does not project a pre-registration user into the network state" do
    user = build(:user, registered: false)

    assert {:error, :unregistered_user} =
             Projection.user(user, user.home_boot, sid: "root", policy_epoch: Identity.nonce())
  end

  test "does not publish a binding for a missing or stale account record" do
    user = insert(:user, nick: "Alice", identified_as: "Missing")

    assert {:ok, projection} = Projection.user(user, user.home_boot, sid: "root", policy_epoch: Identity.nonce())
    assert projection["binding"] == nil
  end

  test "keeps membership status rows paired with their sorted membership entries" do
    user = build(:user, registered: true, membership_rev: 3, home_sid: "root")
    channel_a = %{"name" => "#alpha", "born_ms" => 1, "cid" => Identity.cid()}
    channel_b = %{"name" => "#beta", "born_ms" => 1, "cid" => Identity.cid()}

    record_b =
      build(:user_channel,
        uid: user.uid,
        channel_name_key: "#beta",
        join_id: 8,
        joined_ms: 20,
        modes: [:v]
      )

    record_a =
      build(:user_channel,
        uid: user.uid,
        channel_name_key: "#alpha",
        join_id: 4,
        joined_ms: 10,
        modes: [:o]
      )

    assert {:ok, _membership, statuses} =
             Projection.memberships(
               user,
               [record_b, record_a],
               "root",
               user.home_boot,
               channel_refs: %{"#alpha" => channel_a, "#beta" => channel_b}
             )

    assert Enum.map(statuses, &{&1["channel"]["name"], &1["join_id"], &1["mode"]}) == [
             {"#alpha", 4, "o"},
             {"#beta", 8, "v"}
           ]
  end

  test "publishes a remote binding from the public policy cache without local account tables" do
    account_id = Identity.uid()
    auth_epoch = Identity.auth_epoch()
    policy_epoch = Identity.nonce()

    policy =
      Policy.new(
        epoch: policy_epoch,
        revision: 2,
        ready?: true,
        objects: %{
          {"account", account_id} => %{
            "account_id" => account_id,
            "canonical_name" => "RemoteAlice",
            "display_name" => "RemoteAlice",
            "auth_epoch" => auth_epoch,
            "verified" => true,
            "aliases" => [],
            "settings" => %{}
          }
        }
      )

    user = insert(:user, nick: "RemoteAlice", identified_as: "RemoteAlice", home_sid: "leaf")

    assert {:ok, projection} =
             Projection.user(user, user.home_boot, sid: "leaf", policy_epoch: policy_epoch, policy: policy)

    assert projection["binding"] == %{
             "account_id" => account_id,
             "auth_epoch" => auth_epoch,
             "policy_epoch" => policy_epoch
           }
  end
end
