defmodule ElixIRCd.Server.S2S.StateTest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.State

  test "stamped registers are commutative for ordered winners" do
    boot = Identity.boot()
    older = [1, "alpha", boot]
    newer = [2, "alpha", boot]

    assert {:ok, :inserted, first} = State.merge_register(nil, older, "old")
    assert {:ok, :updated, second} = State.merge_register(first, newer, "new")
    assert second.value == "new"
    assert {:ok, :unchanged, ^second} = State.merge_register(second, older, "old")
    assert {:error, :stamp_conflict} = State.merge_register(second, newer, "other")
  end

  test "nickname conflicts choose the smallest UID and keep fallbacks injective" do
    users = [
      %{uid: "AAAAAAAAAAAAAAAAAAAAAAAAAA", requested_nick: "Rafael"},
      %{uid: "BAAAAAAAAAAAAAAAAAAAAAAAAA", requested_nick: "rafael"}
    ]

    assert {:ok, projection} = State.nickname_projection(users, case_mapping: :ascii)
    assert projection["AAAAAAAAAAAAAAAAAAAAAAAAAA"] == "Rafael"
    assert projection["BAAAAAAAAAAAAAAAAAAAAAAAAA"] == State.fallback_nickname("BAAAAAAAAAAAAAAAAAAAAAAAAA")
    assert length(Map.values(projection)) == length(Enum.uniq(Map.values(projection)))
  end

  test "nickname collision groups follow the configured IRC case mapping" do
    bracket_claims = [
      %{uid: "AAAAAAAAAAAAAAAAAAAAAAAAAA", requested_nick: "[Name]"},
      %{uid: "BAAAAAAAAAAAAAAAAAAAAAAAAA", requested_nick: "{name}"}
    ]

    assert {:ok, ascii} = State.nickname_projection(bracket_claims, case_mapping: :ascii)
    assert ascii["AAAAAAAAAAAAAAAAAAAAAAAAAA"] == "[Name]"
    assert ascii["BAAAAAAAAAAAAAAAAAAAAAAAAA"] == "{name}"

    for mapping <- [:strict_rfc1459, :rfc1459] do
      assert {:ok, projection} = State.nickname_projection(bracket_claims, case_mapping: mapping)
      assert projection["AAAAAAAAAAAAAAAAAAAAAAAAAA"] == "[Name]"
      assert projection["BAAAAAAAAAAAAAAAAAAAAAAAAA"] == State.fallback_nickname("BAAAAAAAAAAAAAAAAAAAAAAAAA")
    end

    caret_claims = [
      %{uid: "AAAAAAAAAAAAAAAAAAAAAAAAAA", requested_nick: "Caret^"},
      %{uid: "BAAAAAAAAAAAAAAAAAAAAAAAAA", requested_nick: "caret~"}
    ]

    assert {:ok, strict} = State.nickname_projection(caret_claims, case_mapping: :strict_rfc1459)
    assert strict["BAAAAAAAAAAAAAAAAAAAAAAAAA"] == "caret~"

    assert {:ok, rfc1459} = State.nickname_projection(caret_claims, case_mapping: :rfc1459)
    assert rfc1459["BAAAAAAAAAAAAAAAAAAAAAAAAA"] == State.fallback_nickname("BAAAAAAAAAAAAAAAAAAAAAAAAA")
  end

  test "recognizes only canonical generated fallbacks and reserves another UID's fallback" do
    uid = Identity.uid()
    other_uid = Identity.uid()
    fallback = State.fallback_nickname(uid)

    assert State.fallback_nickname?(fallback)
    assert State.fallback_nickname?(String.downcase(fallback))
    assert State.fallback_nickname_for?(fallback, uid)
    refute State.fallback_nickname_for?(fallback, other_uid)
    refute State.fallback_nickname?("G" <> String.duplicate("A", 25) <> "8")

    assert {:error, :invalid_requested_nick} =
             State.nickname_projection([%{uid: other_uid, requested_nick: fallback}], case_mapping: :ascii)
  end

  test "complete membership replacement reports omitted and changed entries" do
    old = [
      %{"channel" => "#one", "join_id" => 1, "joined_ms" => 10},
      %{"channel" => "#two", "join_id" => 2, "joined_ms" => 20}
    ]

    new = [
      %{"channel" => "#one", "join_id" => 3, "joined_ms" => 30},
      %{"channel" => "#three", "join_id" => 4, "joined_ms" => 40}
    ]

    assert {:ok, diff} = State.replace_memberships(1, old, 2, new, case_mapping: :ascii)
    assert diff.removed == [Enum.at(old, 1)]
    assert diff.added == [Enum.at(new, 1)]
    assert diff.changed == [Enum.at(new, 0)]
    assert {:error, :membership_revision_conflict} = State.replace_memberships(1, old, 1, new)
  end

  test "list tombstones defeat stale additions and retain capacity" do
    channel = %{list_slots: %{}, list_slot_limit: 1}
    boot = Identity.boot()

    assert {:ok, channel, :inserted} = State.merge_list_slot(channel, "mask", [1, "alpha", boot], true, %{set_by: "a"})
    assert {:ok, channel, :updated} = State.merge_list_slot(channel, "mask", [2, "alpha", boot], false, %{set_by: "b"})
    assert {:ok, channel, :unchanged} = State.merge_list_slot(channel, "mask", [1, "alpha", boot], true, %{set_by: "a"})
    assert channel.list_slots["mask"].value.present == false
    assert {:error, :slot_capacity} = State.merge_list_slot(channel, "other", [3, "alpha", boot], true)
  end
end
