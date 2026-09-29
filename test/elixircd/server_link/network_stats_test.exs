defmodule ElixIRCd.ServerLink.NetworkStatsTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.ServerLink.NetworkStats
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.Route
  alias ElixIRCd.ServerLink.UserPayload

  test "publishes all committed UIDs, transitive routes and selected channels in one typed snapshot" do
    table = NetworkStats.create()
    first_uid = UserPayload.new_uid()
    second_uid = UserPayload.new_uid()
    first = build(:user, nick: "Visible") |> UserPayload.from_local(first_uid)
    second = build(:user, nick: "Hidden", modes: [:i, :o]) |> UserPayload.from_local(second_uid)

    replica = %{
      Replica.new()
      | users: %{{"east.example", first_uid} => first, {"west.example", second_uid} => second}
    }

    routes = %{
      "east.example" => %Route{via: "east.example", epoch: first_uid, path: ["east.example", "irc.test"]},
      "west.example" => %Route{
        via: "east.example",
        epoch: second_uid,
        path: ["west.example", "east.example", "irc.test"]
      }
    }

    assert :ok = NetworkStats.publish(table, replica, routes, %{"east.example" => self()}, %{"#one" => :selected})

    assert {:ok,
            %NetworkStats{
              remote_visible: 1,
              remote_invisible: 1,
              remote_operators: 1,
              remote_servers: 2,
              direct_servers: 1,
              channels: 1
            }} = NetworkStats.get()

    assert :ok = NetworkStats.publish(table, Replica.new(), %{}, %{}, %{})
    assert {:ok, %NetworkStats{remote_servers: 0, channels: 0}} = NetworkStats.get()
  end
end
