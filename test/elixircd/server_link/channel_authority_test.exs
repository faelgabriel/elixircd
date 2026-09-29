defmodule ElixIRCd.ServerLink.ChannelAuthorityTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias ElixIRCd.Factory
  alias ElixIRCd.ServerLink.ChannelAuthority
  alias ElixIRCd.ServerLink.ChannelAuthority.Winner
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.Utils.CaseMapping

  test "oldest channel timestamp wins and server ID breaks exact ties" do
    created_at = ~U[2026-09-29 00:00:00Z]
    local = Factory.build(:channel, name: "#Room", created_at: DateTime.add(created_at, 1, :second))
    remote = Factory.build(:channel, name: "#room", created_at: created_at)
    key = CaseMapping.normalize("#room")
    local_channels = %{key => ChannelPayload.from_local(local, "west.example")}
    remote_channels = %{{"east.example", key} => ChannelPayload.from_local(remote, "east.example")}

    selected = ChannelAuthority.select("west.example", local_channels, remote_channels)

    assert {:ok, %Winner{origin: "east.example", remote_present: true, channel: %{"name" => "#room"}}} =
             ChannelAuthority.get(selected, "#ROOM")

    tied_local = Factory.build(:channel, name: "#Room", created_at: created_at)

    tied =
      ChannelAuthority.select(
        "west.example",
        %{key => ChannelPayload.from_local(tied_local, "west.example")},
        remote_channels
      )

    assert {:ok, %{origin: "east.example"}} = ChannelAuthority.get(tied, "#room")

    mirrored =
      ChannelAuthority.select(
        "west.example",
        %{key => ChannelPayload.from_local(tied_local, "east.example")},
        remote_channels
      )

    assert {:ok, %{origin: "east.example"}} = ChannelAuthority.get(mirrored, "#room")

    surviving_mirror =
      ChannelAuthority.select("west.example", %{key => ChannelPayload.from_local(tied_local, "east.example")}, %{})

    assert {:ok, %{origin: "west.example", channel: %{"creator" => "east.example"}}} =
             ChannelAuthority.get(surviving_mirror, "#room")

    late_creator =
      ChannelAuthority.select(
        "a.example",
        %{key => ChannelPayload.from_local(tied_local, "z.example")},
        %{{"z.example", key} => ChannelPayload.from_local(remote, "z.example")}
      )

    assert {:ok, %{origin: "z.example"}} = ChannelAuthority.get(late_creator, "#room")

    after_split = ChannelAuthority.select("west.example", local_channels, %{})
    assert {:ok, %{origin: "west.example", remote_present: false}} = ChannelAuthority.get(after_split, "#room")

    older_local = Factory.build(:channel, name: "#Room", created_at: DateTime.add(created_at, -1, :second))

    with_remote_policy =
      ChannelAuthority.select(
        "west.example",
        %{key => ChannelPayload.from_local(older_local, "west.example")},
        remote_channels
      )

    assert {:ok, %{origin: "west.example", remote_present: true}} = ChannelAuthority.get(with_remote_policy, "#room")
    assert :error = ChannelAuthority.get(after_split, "#missing")
  end
end
