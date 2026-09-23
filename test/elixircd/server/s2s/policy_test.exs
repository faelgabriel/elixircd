defmodule ElixIRCd.Server.S2S.PolicyTest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Policy

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

  test "projects and applies only public account data" do
    id = Identity.uid()
    assert {:ok, projection} = Policy.project_account(account(id))
    refute Map.has_key?(projection, "password")

    state = Policy.new(epoch: Identity.nonce())
    change = %{"entity" => "account", "key" => id, "value" => projection}
    assert {:ok, state, :applied} = Policy.apply_change(state, state.epoch, 1, [change])
    assert {:ok, ^projection} = Policy.get(state, "account", id)
    assert Policy.grant_ready?(state)
    assert {:ok, ^state, :unchanged} = Policy.apply_change(state, state.epoch, 1, [change])
  end

  test "revision gaps and oversized invalidations fail closed" do
    state = Policy.new(epoch: Identity.nonce())
    assert {:error, {:policy_revision_gap, 1, 2}} = Policy.apply_change(state, state.epoch, 2, [])
    assert {:ok, invalidated, :invalidated} = Policy.apply_change(state, state.epoch, 1, nil)
    refute Policy.grant_ready?(invalidated)
  end

  test "full image replaces deleted objects atomically" do
    id = Identity.uid()
    projection = account(id)
    state = Policy.new(epoch: Identity.nonce(), revision: 1, objects: %{{"account", id} => projection}, ready?: true)
    assert {:ok, installed} = Policy.install_image(state, state.epoch, 2, [])
    assert Policy.get(installed, "account", id) == :not_found
    assert installed.revision == 2
    assert Policy.grant_ready?(installed)
    assert {:error, :invalid_policy_image} = Policy.install_image(installed, installed.epoch, 1, [])
  end

  test "rejects a different complete image at an already ready revision" do
    first_id = Identity.uid()
    second_id = Identity.uid()
    {:ok, first_projection} = Policy.project_account(account(first_id))
    {:ok, second_projection} = Policy.project_account(account(second_id))

    state =
      Policy.new(
        epoch: Identity.nonce(),
        revision: 4,
        objects: %{{"account", first_id} => first_projection},
        ready?: true
      )

    assert {:error, :policy_revision_conflict} =
             Policy.install_image(state, state.epoch, state.revision, [
               %{"entity" => "account", "key" => second_id, "value" => second_projection}
             ])

    assert {:ok, recovered} =
             Policy.install_image(%{state | ready?: false}, state.epoch, state.revision, [
               %{"entity" => "account", "key" => second_id, "value" => second_projection}
             ])

    assert Policy.get(recovered, "account", second_id) == {:ok, second_projection}
  end

  test "policy deletions validate the entity key namespace" do
    state = Policy.new(epoch: Identity.nonce(), revision: 1)

    assert {:error, :invalid_policy_change} =
             Policy.apply_change(state, state.epoch, 2, [%{"entity" => "account", "key" => "not-an-id", "value" => nil}])
  end

  test "image payloads have begin and end boundaries" do
    state = Policy.new(epoch: Identity.nonce(), revision: 3)
    assert {:ok, [begin, ending]} = Policy.image_payloads(state, 2)
    assert begin["phase"] == "begin"
    assert ending["phase"] == "end"
    assert begin["objects"] == ending["objects"]
  end

  test "authority image projects aliases, reservations and channel ACLs without secrets" do
    account_id = Identity.uid()
    epoch = Identity.nonce()

    nicks = [
      %{
        nickname_key: "account",
        nickname: "Account",
        account_name_key: "account",
        account_name: "Account",
        account_id: account_id,
        auth_epoch: 1,
        password_hash: "secret-hash",
        scram_sha_256: nil,
        verified_at: DateTime.utc_now(),
        reserved_until: nil,
        settings: %{display: "Account", secure: true}
      },
      %{
        nickname_key: "alias",
        nickname: "Alias",
        account_name_key: "account",
        account_name: "Account",
        account_id: account_id,
        auth_epoch: 1,
        password_hash: "alias-hash",
        scram_sha_256: nil,
        verified_at: nil,
        reserved_until: ~U[2030-01-01 00:00:00Z],
        settings: %{}
      }
    ]

    channels = [
      %{
        name_key: "#elixir",
        name: "#elixir",
        founder: "Account",
        successor: nil,
        settings: %{},
        topic: nil,
        created_at: DateTime.utc_now()
      }
    ]

    access = [%{channel_name_key: "#elixir", account_name_key: "account", flags: "VAFST"}]

    assert {:ok, state} = Policy.from_sources(epoch, nicks, channels, access, [], revision: 4)
    assert state.revision == 4
    assert Policy.grant_ready?(state)
    assert {:ok, account} = Policy.get(state, "account", account_id)
    refute Map.has_key?(account, "password_hash")
    assert account["aliases"] == ["Account", "Alias"]
    assert {:ok, nick} = Policy.get(state, "nick", "alias")
    assert nick["reserved_until_ms"] > 0
    assert {:ok, channel} = Policy.get(state, "channel", "#elixir")
    assert channel["access"] == [[account_id, "VAFST"]]
  end
end
