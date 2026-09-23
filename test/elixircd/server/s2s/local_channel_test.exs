defmodule ElixIRCd.Server.S2S.LocalChannelTest do
  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.LocalChannel
  alias ElixIRCd.Server.S2S.Runtime

  defp config do
    [
      s2s: [
        server_id: "root",
        roster: [[sid: "root", name: "root.example.test", parent: nil]]
      ],
      settings: [case_mapping: :ascii]
    ]
  end

  test "refreshes a materialized channel from the canonical runtime projection" do
    insert(:channel, name: "#remote", topic: nil)
    {:ok, runtime} = Runtime.new(config())

    reference = %{"name" => "#remote", "born_ms" => 1, "cid" => Identity.cid()}

    assert {:ok, runtime, _effects} =
             Runtime.apply_local_row(runtime, %{"kind" => "channel.ensure", "channel" => reference})

    assert {:ok, runtime, _effects} =
             Runtime.apply_local_row(runtime, %{
               "kind" => "channel.field",
               "channel" => reference,
               "field" => "topic",
               "value" => %{"text" => "remote topic", "setter" => "root", "set_ms" => 2},
               "stamp" => [2, "root", runtime.boot],
               "setter" => %{"server" => "root"}
             })

    assert :ok = LocalChannel.reconcile(runtime, "#remote")

    assert {:ok, channel} = Memento.transaction!(fn -> Channels.get_by_name("#remote") end)
    assert channel.cid == reference["cid"]
    assert channel.topic.text == "remote topic"
  end

  test "materializes a learned channel when the local row is absent" do
    {:ok, runtime} = Runtime.new(config())

    reference = %{"name" => "#learned", "born_ms" => 1, "cid" => Identity.cid()}

    assert {:ok, runtime, _effects} =
             Runtime.apply_local_row(runtime, %{"kind" => "channel.ensure", "channel" => reference})

    assert {:error, :channel_not_found} =
             Memento.transaction!(fn -> Channels.get_by_name("#learned") end)

    assert :ok = LocalChannel.reconcile(runtime, "#learned")

    assert {:ok, channel} = Memento.transaction!(fn -> Channels.get_by_name("#learned") end)
    assert channel.cid == reference["cid"]
    assert channel.name == "#learned"
  end

  test "invalidates invitations when a channel incarnation is replaced" do
    user = insert(:user)
    previous = insert(:channel, name: "#reincarnated", born_ms: 20, cid: Identity.cid())
    insert(:user_channel, user: user, channel: previous, modes: [:o, :v])
    insert(:channel_ban, channel: previous, mask: "*!*@old.example")
    insert(:channel_invite, channel: previous, user: user)
    {:ok, runtime} = Runtime.new(config())
    replacement = %{"name" => previous.name, "born_ms" => 10, "cid" => Identity.cid()}

    assert {:ok, runtime, _effects} =
             Runtime.apply_local_row(runtime, %{"kind" => "channel.ensure", "channel" => replacement})

    assert :ok = LocalChannel.reconcile(runtime, previous.name)

    assert {:error, :channel_invite_not_found} =
             Memento.transaction!(fn -> ChannelInvites.get_by_user_pid_and_channel_name(user.pid, previous.name) end)

    assert [] == Memento.transaction!(fn -> ChannelBans.get_by_channel_name_key(previous.name_key) end)

    assert {:ok, membership} =
             Memento.transaction!(fn -> UserChannels.get_by_user_pid_and_channel_name(user.pid, previous.name) end)

    assert membership.modes == []

    assert {:ok, channel} = Memento.transaction!(fn -> Channels.get_by_name(previous.name) end)
    assert channel.born_ms == replacement["born_ms"]
    assert channel.cid == replacement["cid"]
  end

  test "prunes an empty local projection after runtime channel extinction" do
    insert(:channel, name: "#expired", topic: nil)

    assert :ok = LocalChannel.prune(%{}, "#expired")
    assert {:error, :channel_not_found} = Memento.transaction!(fn -> Channels.get_by_name("#expired") end)
  end
end
