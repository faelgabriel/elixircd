defmodule ElixIRCd.ServerLink.ChannelViewTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias ElixIRCd.Factory
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.ChannelView.RemoteMember
  alias ElixIRCd.ServerLink.ChannelView.RemoteRecord
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.Utils.CaseMapping

  test "read view follows committed remote members, policy lists, invites and user profile" do
    channel = Factory.build(:channel, name: "#Shared")
    key = CaseMapping.normalize(channel.name)
    payload = ChannelPayload.from_local(channel, "irc.test")
    user = %{"uid" => "remote-uid", "nick" => "Remote"}
    member = %{"channel" => "#Shared", "uid" => "remote-uid", "modes" => ["o"]}
    ban = %{"channel" => "#Shared", "kind" => "b", "mask" => "*!*@blocked.test"}
    invite = %{"channel" => "#Shared", "uid" => "remote-uid"}

    replica = %{
      Replica.new()
      | channels: %{{"east.example", key} => payload},
        users: %{{"east.example", "remote-uid"} => user},
        members: %{{"east.example", {key, "remote-uid"}} => member},
        lists: %{{"east.example", {key, "b", "*!*@blocked.test"}} => ban},
        invites: %{{"east.example", {key, "remote-uid"}} => invite}
    }

    local_channels = %{key => payload}
    view = ChannelView.select("irc.test", local_channels, replica)[key]
    assert %ChannelView{} = view

    assert view.origin == "irc.test"
    assert view.remote_present

    assert view.remote_members == [
             %RemoteMember{origin: "east.example", member: member, user: user, effective_modes: ["o"]}
           ]

    assert view.remote_lists == [%RemoteRecord{origin: "east.example", entry: ban, effective: true}]
    assert view.remote_invites == [%RemoteRecord{origin: "east.example", entry: invite, effective: true}]

    updated = %{replica | users: %{{"east.example", "remote-uid"} => %{user | "nick" => "Renamed"}}}

    assert [%{user: %{"nick" => "Renamed"}}] =
             ChannelView.select("irc.test", local_channels, updated)[key].remote_members

    losing_channel = Factory.build(:channel, name: "#Shared", created_at: DateTime.add(channel.created_at, 1))

    losing_replica = %{
      replica
      | channels: %{{"east.example", key} => ChannelPayload.from_local(losing_channel, "east.example")}
    }

    losing_view = ChannelView.select("irc.test", local_channels, losing_replica)[key]
    assert [%{effective_modes: []}] = losing_view.remote_members
    assert [%{effective: false}] = losing_view.remote_lists
    assert [%{effective: false}] = losing_view.remote_invites

    after_split = ChannelView.select("irc.test", local_channels, Replica.new())[key]
    refute after_split.remote_present
    assert after_split.remote_members == []
    assert after_split.remote_lists == []
    assert after_split.remote_invites == []
  end
end
