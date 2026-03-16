defmodule ElixIRCd.Services.Chanserv.Channel.ModerationTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Services.Chanserv.Channel.Moderation
  alias ElixIRCd.Tables.RegisteredChannel.Settings

  describe "ensure_peace/4" do
    test "allows moderation when PEACE is disabled" do
      Memento.transaction!(fn ->
        registered_channel = insert(:registered_channel, settings: Settings.new(%{peace: false}))
        user = insert(:user, identified_as: "alice")
        target = insert(:user, identified_as: "bob")

        assert :ok = Moderation.ensure_peace(registered_channel, user, [target], %{"alice" => "S", "bob" => "S"})
      end)
    end

    test "denies moderation against a user with equal or higher access when PEACE is enabled" do
      Memento.transaction!(fn ->
        registered_channel = insert(:registered_channel, founder: "founder", settings: Settings.new(%{peace: true}))
        user = insert(:user, identified_as: "alice")
        target = insert(:user, identified_as: "bob")

        assert {:error, :peace_denied} =
                 Moderation.ensure_peace(registered_channel, user, [target], %{"alice" => "S", "bob" => "S"})
      end)
    end

    test "allows founders to bypass PEACE restrictions" do
      Memento.transaction!(fn ->
        registered_channel = insert(:registered_channel, founder: "alice", settings: Settings.new(%{peace: true}))
        user = insert(:user, identified_as: "alice")
        target = insert(:user, identified_as: "bob")

        assert :ok =
                 Moderation.ensure_peace(registered_channel, user, [target], %{"alice" => "S", "bob" => "T"})
      end)
    end
  end

  describe "kick_targets/3" do
    test "uses the default reason and cleans up an empty channel" do
      Memento.transaction!(fn ->
        target = insert(:user)
        channel = insert(:channel, name: "#testchannel")

        insert(:user_channel, user: target, channel: channel)
        ChannelInvites.create(%{user_pid: target.pid, channel_name_key: channel.name_key, setter: "setter"})

        assert 1 == Moderation.kick_targets(channel, [target], nil)

        assert {:error, :user_channel_not_found} =
                 UserChannels.get_by_user_pid_and_channel_name(target.pid, channel.name)

        assert {:error, :channel_invite_not_found} =
                 ChannelInvites.get_by_user_pid_and_channel_name(target.pid, channel.name)

        assert {:error, :channel_not_found} = Channels.get_by_name(channel.name)

        assert_sent_messages([
          {target.pid, ":ChanServ!service@irc.test KICK #{channel.name} #{target.nick} :Requested by ChanServ\r\n"}
        ])
      end)
    end

    test "skips targets that are no longer on the channel" do
      Memento.transaction!(fn ->
        target = insert(:user)
        channel = insert(:channel, name: "#testchannel")

        assert 0 == Moderation.kick_targets(channel, [target], "Reason")

        assert_sent_messages([])
      end)
    end
  end
end
