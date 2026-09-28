defmodule ElixIRCd.Services.Chanserv.RecoverTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Join
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Services.Chanserv.Recover

  test "identified founder regains +o and removes other live operators" do
    founder = insert(:user, identified_as: "Founder")
    intruder = insert(:user)
    channel = insert(:channel, name: "#taken")
    insert(:registered_channel, name: channel.name, founder: "Founder")
    insert(:user_channel, user: founder, channel: channel)
    insert(:user_channel, user: intruder, channel: channel, modes: [:o])

    assert :ok = run(fn -> Recover.handle(founder, ["RECOVER", channel.name]) end)

    Memento.transaction!(fn ->
      assert {:ok, %{modes: modes}} = UserChannels.get_by_user_pid_and_channel_name(founder.pid, channel.name)
      assert :o in modes
      assert {:ok, %{modes: []}} = UserChannels.get_by_user_pid_and_channel_name(intruder.pid, channel.name)
    end)

    assert_sent_message_contains(founder.pid, ~r/MODE #taken -o/)
    assert_sent_message_contains(founder.pid, ~r/MODE #taken \+o/)
  end

  test "recovery invite lets the founder rejoin a locked channel with +o" do
    founder = insert(:user, identified_as: "Founder")
    intruder = insert(:user)
    channel = insert(:channel, name: "#taken", modes: [:i, {:k, "secret"}])
    insert(:registered_channel, name: channel.name, founder: "Founder")
    insert(:user_channel, user: intruder, channel: channel, modes: [:o])

    assert :ok = run(fn -> Recover.handle(founder, ["RECOVER", channel.name]) end)

    Memento.transaction!(fn ->
      assert {:ok, %{bypass_ban: true}} = ChannelInvites.get_by_user_pid_and_channel_name(founder.pid, channel.name)
    end)

    assert :ok = run(fn -> Join.handle(founder, %Message{command: "JOIN", params: [channel.name]}) end)

    Memento.transaction!(fn ->
      assert {:ok, %{modes: modes}} = UserChannels.get_by_user_pid_and_channel_name(founder.pid, channel.name)
      assert :o in modes

      assert {:error, :channel_invite_not_found} =
               ChannelInvites.get_by_user_pid_and_channel_name(founder.pid, channel.name)
    end)
  end

  test "recovery invite preserves secure-only and IRC operator-only join restrictions" do
    founder = insert(:user, identified_as: "Founder")
    intruder = insert(:user)
    channel = insert(:channel, name: "#secure", modes: [:i, :z, :O])
    insert(:registered_channel, name: channel.name, founder: "Founder")
    insert(:user_channel, user: intruder, channel: channel, modes: [:o])

    assert :ok = run(fn -> Recover.handle(founder, ["RECOVER", channel.name]) end)
    assert :ok = run(fn -> Join.handle(founder, %Message{command: "JOIN", params: [channel.name]}) end)
    assert_sent_message_contains(founder.pid, ~r/SSL\/TLS required \(\+z\)/)

    secure_founder = %{founder | modes: [:Z]}
    assert :ok = run(fn -> Join.handle(secure_founder, %Message{command: "JOIN", params: [channel.name]}) end)
    assert_sent_message_contains(founder.pid, ~r/Only IRC operators may join this channel/)

    Memento.transaction!(fn ->
      assert {:error, :user_channel_not_found} =
               UserChannels.get_by_user_pid_and_channel_name(founder.pid, channel.name)
    end)
  end

  test "non-founders cannot recover a channel" do
    outsider = insert(:user, identified_as: "Other")
    channel = insert(:channel, name: "#taken")
    insert(:registered_channel, name: channel.name, founder: "Founder")

    assert :ok = run(fn -> Recover.handle(outsider, ["RECOVER", channel.name]) end)
    assert_sent_message_contains(outsider.pid, ~r/Only the channel founder/)
  end

  test "RECOVER reports missing channels, idle channels, and invalid requests" do
    founder = insert(:user, identified_as: "Founder")
    anonymous = insert(:user)
    insert(:registered_channel, name: "#idle", founder: "Founder")

    assert :ok = run(fn -> Recover.handle(anonymous, ["RECOVER", "#idle"]) end)
    assert_sent_message_contains(anonymous.pid, ~r/must be identified/)
    assert :ok = run(fn -> Recover.handle(founder, ["RECOVER"]) end)
    assert_sent_message_contains(founder.pid, ~r/Syntax:.*RECOVER/)
    assert :ok = run(fn -> Recover.handle(founder, ["RECOVER", "#missing"]) end)
    assert_sent_message_contains(founder.pid, ~r/not registered/)
    assert :ok = run(fn -> Recover.handle(founder, ["RECOVER", "#idle"]) end)
    assert_sent_message_contains(founder.pid, ~r/not currently in use/)
  end

  test "RECOVER tolerates a stale membership when a user record has disappeared" do
    founder = insert(:user, identified_as: "Founder")
    channel = insert(:channel, name: "#stale")
    insert(:registered_channel, name: channel.name, founder: "Founder")
    insert(:user_channel, user: founder, channel: channel)
    stale = insert(:user)
    insert(:user_channel, user: stale, channel: channel, modes: [:o])
    Memento.transaction!(fn -> Users.delete(stale) end)

    assert :ok = run(fn -> Recover.handle(founder, ["RECOVER", channel.name]) end)
    assert_sent_message_contains(founder.pid, ~r/has been recovered/)
  end

  defp run(fun), do: ElixIRCd.Observability.transaction(fun)
end
