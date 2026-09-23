defmodule ElixIRCd.Server.S2S.TreeTest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.Tree

  defp roster do
    [
      %{sid: "root", name: "root.example.test", parent: nil},
      %{sid: "hub", name: "hub.example.test", parent: "root"},
      %{sid: "leaf", name: "leaf.example.test", parent: "hub"},
      %{sid: "other", name: "other.example.test", parent: "root"}
    ]
  end

  test "routes through the unique configured tree path" do
    assert {:ok, ["root", "hub", "leaf"]} = Tree.path(roster(), "root", "leaf")
    assert {:ok, ["leaf", "hub", "root", "other"]} = Tree.path(roster(), "leaf", "other")
    assert {:ok, "hub"} = Tree.next_hop(roster(), "leaf", "other")
    assert Tree.initiator_allowed?(roster(), "leaf", "hub")
    refute Tree.initiator_allowed?(roster(), "hub", "leaf")
  end

  test "active route refuses a path with a missing edge" do
    edges = MapSet.new([{"hub", "root"}])

    assert {:error, :inactive_route} = Tree.active_route(roster(), "root", "leaf", edges)
    assert {:ok, ["root", "hub"]} = Tree.active_route(roster(), "root", "hub", edges)
  end

  test "topology export uses sorted nodes and direct edge descriptors" do
    boots = Map.new(Enum.map(roster(), &{&1.sid, Identity.boot()}))
    row = Tree.topology_row(roster(), boots, [{"root", "hub", String.duplicate("a", 64), ["root", "hub"]}])

    assert row["kind"] == "topology.add"
    assert Enum.map(row["nodes"], & &1["sid"]) == ["hub", "leaf", "other", "root"]
    assert hd(row["edges"])["a"]["sid"] == "hub"
    assert hd(row["edges"])["b"]["sid"] == "root"
  end

  test "validates every branch of a forwarded connected component" do
    boots = Map.new(["root", "hub", "leaf", "other"], &{&1, Identity.boot()})

    nodes =
      Enum.map(boots, fn {sid, boot} ->
        %{"sid" => sid, "boot" => boot, "name" => sid <> ".example.test", "description" => ""}
      end)

    edges = [
      edge("root", "hub", boots, "a"),
      edge("hub", "leaf", boots, "b"),
      edge("root", "other", boots, "c")
    ]

    row = %{"kind" => "topology.add", "nodes" => nodes, "edges" => edges}

    assert :ok = Tree.validate_topology(row, roster(), %{}, "hub")
    assert :ok = Tree.validate_topology(row, roster(), %{}, "other", require_incoming: false)
  end

  defp edge(left, right, boots, suffix) do
    %{
      "id" => String.duplicate(suffix, 64),
      "a" => %{"sid" => left, "boot" => boots[left]},
      "b" => %{"sid" => right, "boot" => boots[right]},
      "ready_sides" => []
    }
  end
end
