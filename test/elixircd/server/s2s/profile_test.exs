defmodule ElixIRCd.Server.S2S.ProfileTest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Profile

  defp config(roster) do
    [
      s2s: [
        enabled: true,
        network_id: "test-net",
        semantic_revision: 1,
        server_id: "root",
        server_name: "root.example.test",
        services_authority: "root",
        roster: roster,
        parent_connection: nil,
        children: %{"leaf" => [pins: [String.duplicate("a", 64)], ips: []]}
      ],
      settings: [case_mapping: :rfc1459, utf8_only: true],
      user: [max_nick_length: 30, max_ident_length: 10, max_realname_length: 50, max_away_message_length: 200],
      channel: [
        channel_prefixes: ["#", "&"],
        channel_join_limits: %{"#" => 20},
        max_channel_name_length: 64,
        max_topic_length: 300,
        max_kick_message_length: 255,
        max_modes_per_command: 20,
        max_list_entries: %{b: 100, e: 100, I: 100}
      ]
    ]
  end

  test "validates a configured tree and hashes roster order canonically" do
    roster = [
      [sid: "leaf", name: "leaf.example.test", parent: "root"],
      [sid: "root", name: "root.example.test", parent: nil]
    ]

    assert :ok = Profile.validate(config(roster))
    assert Profile.hash(config(roster)) == Profile.hash(config(Enum.reverse(roster)))
    assert byte_size(Profile.hash(config(roster))) == 64
  end

  test "builds a schema-valid hello" do
    config = config([[sid: "root", name: "root.example.test", parent: nil]])
    hello = Profile.hello(config, Identity.boot(), Identity.nonce(), 1_700_000_000_000)

    assert hello["sid"] == "root"
    assert ElixIRCd.Server.S2S.Schema.validate_frame(hello) == :ok
  end

  test "rejects a forest and a cycle" do
    forest = [
      [sid: "alpha", name: "alpha.example.test", parent: nil],
      [sid: "beta", name: "beta.example.test", parent: nil]
    ]

    cycle = [
      [sid: "root", name: "root.example.test", parent: "leaf"],
      [sid: "leaf", name: "leaf.example.test", parent: "root"]
    ]

    assert {:error, errors} = Profile.validate_roster(forest)
    assert :root_count in errors
    assert {:error, cycle_errors} = Profile.validate_roster(cycle)
    assert Enum.any?(cycle_errors, &match?({:cycle, _}, &1))
  end

  test "rejects an enabled profile with an unpinned direct child or unknown child entry" do
    roster = [
      [sid: "root", name: "root.example.test", parent: nil],
      [sid: "leaf", name: "leaf.example.test", parent: "root"]
    ]

    missing = put_in(config(roster), [:s2s, :children], %{})
    assert {:error, [:missing_neighbor_credentials]} = Profile.validate(missing)

    unknown = put_in(config(roster), [:s2s, :children], %{"other" => [pins: [String.duplicate("a", 64)], ips: []]})
    assert {:error, [:missing_neighbor_credentials, :unknown_child_configuration]} = Profile.validate(unknown)
  end
end
