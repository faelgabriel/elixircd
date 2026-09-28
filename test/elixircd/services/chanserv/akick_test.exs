defmodule ElixIRCd.Services.Chanserv.AkickTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Join
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.RegisteredChannelAkicks
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Services.Chanserv.Akick
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.RegisteredChannelAkick

  test "account AKICK persists across channel recreation and blocks JOIN until removed" do
    founder = insert(:user, identified_as: "Founder")
    excluded = insert(:user, identified_as: "Excluded")
    insert(:registered_nick, nickname: "Excluded")
    insert(:registered_channel, name: "#protected", founder: "Founder")

    assert :ok = run(fn -> Akick.handle(founder, ["AKICK", "#protected", "ADD", "Excluded", "abuse"]) end)

    Memento.transaction!(fn ->
      assert [%{kind: :account, target: "Excluded", reason: "abuse"}] = RegisteredChannelAkicks.list("#protected")
    end)

    assert :ok = run(fn -> Join.handle(excluded, %Message{command: "JOIN", params: ["#protected"]}) end)

    Memento.transaction!(fn ->
      assert {:error, :user_channel_not_found} =
               UserChannels.get_by_user_pid_and_channel_name(excluded.pid, "#protected")
    end)

    assert_sent_message_contains(excluded.pid, ~r/ 474 /)

    assert :ok = run(fn -> Akick.handle(founder, ["AKICK", "#protected", "DEL", "Excluded"]) end)
    assert :ok = run(fn -> Join.handle(excluded, %Message{command: "JOIN", params: ["#protected"]}) end)

    Memento.transaction!(fn ->
      assert {:ok, _membership} = UserChannels.get_by_user_pid_and_channel_name(excluded.pid, "#protected")
    end)
  end

  test "AKICK requires channel moderation access and protects the founder" do
    founder = insert(:user, identified_as: "Founder")
    outsider = insert(:user, identified_as: "Outsider")
    insert(:registered_nick, nickname: "Founder")
    insert(:registered_channel, name: "#protected", founder: "Founder")

    assert :ok = run(fn -> Akick.handle(outsider, ["AKICK", "#protected", "ADD", "Founder"]) end)
    assert_sent_message_contains(outsider.pid, ~r/Access denied/)

    assert :ok = run(fn -> Akick.handle(founder, ["AKICK", "#protected", "ADD", "Founder"]) end)
    assert_sent_message_contains(founder.pid, ~r/protected by channel access/)

    Memento.transaction!(fn -> assert RegisteredChannelAkicks.list("#protected") == [] end)
  end

  test "AKICK ENFORCE removes matching live users and CLEAR deletes persistent entries" do
    founder = insert(:user, identified_as: "Founder")
    target = insert(:user, identified_as: nil, hostname: "bad.example")
    channel = insert(:channel, name: "#protected")
    insert(:registered_channel, name: channel.name, founder: "Founder")
    insert(:user_channel, user: founder, channel: channel, modes: [:o])
    insert(:user_channel, user: target, channel: channel)

    assert :ok =
             run(fn -> Akick.handle(founder, ["AKICK", channel.name, "ADD", "*!~username@bad.example", "abuse"]) end)

    Memento.transaction!(fn ->
      assert {:error, :user_channel_not_found} = UserChannels.get_by_user_pid_and_channel_name(target.pid, channel.name)
      assert [_entry] = RegisteredChannelAkicks.list(channel.name)
    end)

    assert :ok = run(fn -> Akick.handle(founder, ["AKICK", channel.name, "CLEAR"]) end)
    Memento.transaction!(fn -> assert RegisteredChannelAkicks.list(channel.name) == [] end)
  end

  test "AKICK validates access, targets, list management, and capacity" do
    founder = insert(:user, identified_as: "Founder")
    anonymous = insert(:user)
    insert(:user, nick: "Online", hostname: "private.example", cloaked_hostname: "online.example", modes: [:x])
    insert(:registered_nick, nickname: "Excluded")
    insert(:registered_channel, name: "#protected", founder: "Founder")

    assert :ok = run(fn -> Akick.handle(anonymous, ["AKICK", "#protected", "LIST"]) end)
    assert_sent_message_contains(anonymous.pid, ~r/must be identified/)
    assert :ok = run(fn -> Akick.handle(founder, ["AKICK", "#missing", "LIST"]) end)
    assert_sent_message_contains(founder.pid, ~r/not registered/)
    assert :ok = run(fn -> Akick.handle(founder, ["AKICK"]) end)
    assert_sent_message_contains(founder.pid, ~r/Syntax:.*AKICK/)
    assert :ok = run(fn -> Akick.handle(founder, ["AKICK", "#protected", "WRONG"]) end)

    assert :ok = run(fn -> Akick.handle(founder, ["AKICK", "#protected", "ADD", "Unknown"]) end)
    assert_sent_message_contains(founder.pid, ~r/Specify a registered nickname/)
    assert :ok = run(fn -> Akick.handle(founder, ["AKICK", "#protected", "ADD", "bad@foo/bar"]) end)
    assert_sent_message_contains(founder.pid, ~r/Specify a registered nickname/)
    assert :ok = run(fn -> Akick.handle(founder, ["AKICK", "#protected", "ADD", "Online"]) end)

    Memento.transaction!(fn ->
      assert [%{kind: :mask, target: "*!*@online.example"}] = RegisteredChannelAkicks.list("#protected")
    end)

    assert :ok = run(fn -> Akick.handle(founder, ["AKICK", "#protected", "ADD", "$a:Excluded"]) end)
    assert :ok = run(fn -> Akick.handle(founder, ["AKICK", "#protected", "ADD", "$a:Missing"]) end)
    assert :ok = run(fn -> Akick.handle(founder, ["AKICK", "#protected", "ADD", "Excluded"]) end)
    assert_sent_message_contains(founder.pid, ~r/already exists/)
    assert :ok = run(fn -> Akick.handle(founder, ["AKICK", "#protected", "DEL", "Missing"]) end)
    assert_sent_message_contains(founder.pid, ~r/No matching AKICK/)
    assert :ok = run(fn -> Akick.handle(founder, ["AKICK", "#protected", "LIST"]) end)
    assert_sent_message_contains(founder.pid, ~r/AKICK list for/)
    assert_sent_message_contains(founder.pid, ~r/account: Excluded/)
    assert :ok = run(fn -> Akick.handle(founder, ["AKICK", "#protected", "ENFORCE"]) end)
    assert_sent_message_contains(founder.pid, ~r/will apply when/)

    Memento.transaction!(fn ->
      Enum.each(1..98, fn n ->
        RegisteredChannelAkicks.put(
          RegisteredChannelAkick.new("#protected", :mask, "*!*@host#{n}.example", nil, "Founder")
        )
      end)
    end)

    assert :ok = run(fn -> Akick.handle(founder, ["AKICK", "#protected", "ADD", "*!*@extra.example"]) end)
    assert_sent_message_contains(founder.pid, ~r/AKICK list is full/)
  end

  test "PEACE protects equal-ranked accounts from AKICK and enforcement" do
    founder = insert(:user, identified_as: "Founder")
    moderator = insert(:user, identified_as: "Moderator")
    target = insert(:user, identified_as: "Target")
    insert(:registered_nick, nickname: "Moderator")
    insert(:registered_nick, nickname: "Target")
    settings = RegisteredChannel.Settings.new(%{peace: true})
    channel_name = "#peace"
    insert(:registered_channel, name: channel_name, founder: "Founder", settings: settings)
    insert(:registered_channel_access, channel_name: channel_name, account_name: "Moderator", flags: "S")
    insert(:registered_channel_access, channel_name: channel_name, account_name: "Target", flags: "S")

    assert :ok = run(fn -> Akick.handle(moderator, ["AKICK", channel_name, "ADD", "Target"]) end)
    assert_sent_message_contains(moderator.pid, ~r/protected by channel access/)

    assert :ok = run(fn -> Akick.handle(founder, ["AKICK", channel_name, "ADD", "Target"]) end)
    channel = insert(:channel, name: channel_name)
    insert(:user_channel, user: founder, channel: channel, modes: [:o])
    insert(:user_channel, user: moderator, channel: channel, modes: [:o])
    insert(:user_channel, user: target, channel: channel, modes: [:o])

    assert :ok = run(fn -> Akick.handle(moderator, ["AKICK", channel.name, "ENFORCE"]) end)
    assert_sent_message_contains(moderator.pid, ~r/protected by PEACE/)

    assert :ok = run(fn -> Akick.handle(moderator, ["AKICK", channel.name, "ADD", "*!*@new.example"]) end)
    assert :ok = run(fn -> Akick.handle(moderator, ["AKICK", channel.name, "LIST"]) end)
    assert_sent_message_contains(moderator.pid, ~r/mask:.*new.example/)
  end

  defp run(fun), do: ElixIRCd.Observability.transaction(fun)
end
