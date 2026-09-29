defmodule ElixIRCd.ServerLink.RemoteWhoTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Who
  alias ElixIRCd.Message
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.Directory
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Utils.CaseMapping

  @origin "east.example"
  @uid String.duplicate("a", 32)

  setup do
    Directory.create()
    ChannelDirectory.create()
    :ok
  end

  test "WHO lists a remote-only channel member with the home server and effective status" do
    remote =
      build(:user,
        nick: "Remote",
        ident: "~remote",
        hostname: "real.example",
        cloaked_hostname: "cloak.example",
        modes: [:x]
      )

    channel = build(:channel, name: "#remote-only")
    publish(remote, channel, ["o"])

    Memento.transaction!(fn ->
      viewer = insert(:user, nick: "Viewer")
      assert :ok = Who.handle(viewer, %Message{command: "WHO", params: [channel.name]})

      assert_sent_message_contains(
        viewer.pid,
        ":irc.test 352 Viewer #remote-only ~remote cloak.example east.example Remote H@ :0 realname\r\n"
      )

      assert_sent_message_contains(viewer.pid, ":irc.test 315 Viewer #remote-only :End of WHO list\r\n")

      assert :ok = Who.handle(viewer, %Message{command: "WHO", params: [remote.nick]})

      assert_sent_message_contains(
        viewer.pid,
        ":irc.test 352 Viewer #remote-only ~remote cloak.example east.example Remote H@ :0 realname\r\n"
      )
    end)
  end

  test "WHO mask respects remote invisibility and hidden operator status" do
    remote = build(:user, nick: "Remote", modes: [:i, :o, :H], hostname: "east.example")
    publish(remote)

    Memento.transaction!(fn ->
      viewer = insert(:user, nick: "Viewer")
      assert :ok = Who.handle(viewer, %Message{command: "WHO", params: ["*"]})
      assert_sent_messages_count_containing(viewer.pid, ~r/ 352 .* Remote /, 0)

      assert :ok = Who.handle(viewer, %Message{command: "WHO", params: ["Remote"]})
      assert_sent_message_contains(viewer.pid, ~r/ 352 Viewer \* .* east\.example Remote H :0 realname\r\n/)

      assert :ok = Who.handle(viewer, %Message{command: "WHO", params: ["Remote", "o"]})
      assert_sent_messages_count_containing(viewer.pid, ~r/ 352 .* Remote /, 1)

      operator = insert(:user, nick: "Operator", modes: [:o])
      assert :ok = Who.handle(operator, %Message{command: "WHO", params: ["Remote", "o"]})
      assert_sent_message_contains(operator.pid, ~r/ 352 Operator \* .* east\.example Remote H\* :0 realname\r\n/)
    end)
  end

  test "WHO does not reveal a secret channel or unprivileged auditorium member" do
    remote = build(:user, nick: "Remote", hostname: "east.example", modes: [:i])
    secret = build(:channel, name: "#secret", modes: [:s])
    publish(remote, secret, [])

    Memento.transaction!(fn ->
      outsider = insert(:user, nick: "Outsider")
      assert :ok = Who.handle(outsider, %Message{command: "WHO", params: [secret.name]})
      assert_sent_messages_count_containing(outsider.pid, ~r/ 352 /, 0)
    end)

    auditorium = build(:channel, name: "#auditorium", modes: [:u])
    publish_channel(remote, auditorium, [])

    Memento.transaction!(fn ->
      channel = insert(:channel, name: auditorium.name, created_at: auditorium.created_at, modes: [:u])
      viewer = insert(:user, nick: "Viewer")
      operator = insert(:user, nick: "Operator")
      insert(:user_channel, user: viewer, channel: channel)
      insert(:user_channel, user: operator, channel: channel, modes: [:o])

      assert :ok = Who.handle(viewer, %Message{command: "WHO", params: [channel.name]})
      assert_sent_messages_count_containing(viewer.pid, ~r/ 352 .* Remote /, 0)

      assert :ok = Who.handle(viewer, %Message{command: "WHO", params: ["*"]})
      assert_sent_messages_count_containing(viewer.pid, ~r/ 352 .* Remote /, 0)

      assert :ok = Who.handle(operator, %Message{command: "WHO", params: [channel.name]})
      assert_sent_message_contains(operator.pid, ~r/ 352 Operator #auditorium .* Remote H :0 realname\r\n/)
    end)
  end

  test "WHOX uses replicated account, away, channel status and home server" do
    remote = build(:user, nick: "Remote", identified_as: "Account", away_message: "away")
    channel = build(:channel, name: "#whox")
    publish(remote, channel, ["v"])

    Memento.transaction!(fn ->
      viewer = insert(:user, nick: "Viewer")
      assert :ok = Who.handle(viewer, %Message{command: "WHO", params: [channel.name, "%tcsnfaor,42"]})

      assert_sent_message_contains(
        viewer.pid,
        ":irc.test 354 Viewer 42 #whox east.example Remote G+ Account 1 :realname\r\n"
      )
    end)
  end

  defp publish(remote, channel \\ nil, modes \\ []) do
    payload = UserPayload.from_local(remote, @uid)
    key = CaseMapping.normalize(remote.nick)
    identity = {@origin, @uid}

    Directory.sync(:ets.whereis(:elixircd_server_link_directory), %{users: %{}, nick_keys: %{}}, %{
      users: %{identity => payload},
      nick_keys: %{key => identity}
    })

    if channel, do: publish_channel(remote, channel, modes)
  end

  defp publish_channel(remote, channel, modes) do
    payload = UserPayload.from_local(remote, @uid)

    view = %{
      origin: @origin,
      channel: ChannelPayload.from_local(channel, @origin),
      remote_present: true,
      remote_members: [%{origin: @origin, user: payload, member: %{"uid" => @uid}, effective_modes: modes}],
      remote_lists: [],
      remote_invites: []
    }

    ChannelDirectory.sync(:ets.whereis(:elixircd_server_link_channels), %{}, %{channel.name_key => view})
  end
end
