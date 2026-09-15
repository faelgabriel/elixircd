defmodule ElixIRCd.Services.Chanserv.InviteTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Services.Chanserv.Invite

  describe "handle/2" do
    test "requires identification and validates syntax" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Invite.handle(user, ["INVITE", "#channel"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You must be identified with NickServ to use this command.\r\n"}
        ])

        identified_user = insert(:user, identified_as: "helper")

        assert :ok = Invite.handle(identified_user, ["INVITE"])

        assert_sent_messages([
          {identified_user.pid,
           ":ChanServ!service@irc.test NOTICE #{identified_user.nick} :Syntax: \x02INVITE <channel> [nickname]\x02\r\n"}
        ])
      end)
    end

    test "handles missing channels, offline channels, access denial, offline targets and targets already in channel" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target = insert(:user)

        assert :ok = Invite.handle(user, ["INVITE", "#missing", target.nick])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#missing\x02 is not registered.\r\n"}
        ])

        insert(:registered_channel, name: "#testchannel", founder: "founder")

        assert :ok = Invite.handle(user, ["INVITE", "#testchannel", target.nick])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Access denied for \x02#testchannel\x02.\r\n"}
        ])

        insert(:registered_channel_access, channel_name: "#testchannel", account_name: "helper", flags: "S")

        assert :ok = Invite.handle(user, ["INVITE", "#testchannel", target.nick])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#testchannel\x02 is not currently in use.\r\n"}
        ])

        channel = insert(:channel, name: "#testchannel")

        assert :ok = Invite.handle(user, ["INVITE", channel.name, "missing"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :The nickname \x02missing\x02 is not online.\r\n"}
        ])

        insert(:user_channel, user: target, channel: channel)

        assert :ok = Invite.handle(user, ["INVITE", channel.name, target.nick])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\x02#{target.nick}\x02 is already on \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "invites users and stores invite entries for +i channels" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        target = insert(:user)
        channel = insert(:channel, name: "#testchannel", modes: [:i])

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "S")

        assert :ok = Invite.handle(user, ["INVITE", channel.name, target.nick])

        assert {:ok, _invite} = ChannelInvites.get_by_user_pid_and_channel_name(target.pid, channel.name)

        assert_sent_messages([
          {target.pid, ":ChanServ!service@irc.test INVITE #{target.nick} #{channel.name}\r\n"},
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\x02#{target.nick}\x02 has been invited to \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end

    test "invites the requester when nickname is omitted" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "helper")
        channel = insert(:channel, name: "#testchannel")

        insert(:registered_channel, name: channel.name, founder: "founder")
        insert(:registered_channel_access, channel_name: channel.name, account_name: "helper", flags: "S")

        assert :ok = Invite.handle(user, ["INVITE", channel.name])

        assert {:error, :channel_invite_not_found} =
                 ChannelInvites.get_by_user_pid_and_channel_name(user.pid, channel.name)

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test INVITE #{user.nick} #{channel.name}\r\n"},
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\x02#{user.nick}\x02 has been invited to \x02#{channel.name}\x02.\r\n"}
        ])
      end)
    end
  end
end
