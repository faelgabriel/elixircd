defmodule ElixIRCd.Services.Chanserv.TransferTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Services.Chanserv.Transfer

  describe "handle/2" do
    test "handles TRANSFER command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "founder")

        assert :ok = Transfer.handle(user, ["TRANSFER"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02TRANSFER\x02.\r\n"},
          {user.pid, ~r/ChanServ.*NOTICE.*Syntax: \x02TRANSFER <channel> \[new_founder\]\x02.*/}
        ])
      end)
    end

    test "requires user to be identified" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)
        channel_name = "#testchannel"

        assert :ok = Transfer.handle(user, ["TRANSFER", channel_name])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You must be identified with NickServ to use this command.\r\n"}
        ])
      end)
    end

    test "handles TRANSFER command for non-registered channel" do
      Memento.transaction!(fn ->
        channel_name = "#nonexistentchannel"
        user = insert(:user, identified_as: "founder")

        assert :ok = Transfer.handle(user, ["TRANSFER", channel_name, "newfounder"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#{channel_name}\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "prevents non-founders from transferring channels" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        founder = "realfounder"
        user = insert(:user, identified_as: "notfounder")

        insert(:registered_channel, name: channel_name, founder: founder)

        assert :ok = Transfer.handle(user, ["TRANSFER", channel_name, "newfounder"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Access denied. You are not the founder of \x02#{channel_name}\x02.\r\n"}
        ])

        # Verify channel ownership didn't change
        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.founder == founder
      end)
    end

    test "transfers channel to a registered user" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        founder = "founder"
        new_founder = "newfounder"
        user = insert(:user, identified_as: founder)

        insert(:registered_channel, name: channel_name, founder: founder)
        insert(:registered_nick, nickname: new_founder)

        assert :ok = Transfer.handle(user, ["TRANSFER", channel_name, new_founder])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#{channel_name}\x02 has been transferred to \x02#{new_founder}\x02.\r\n"},
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :They are now the new channel founder.\r\n"}
        ])

        # Verify channel ownership changed
        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.founder == new_founder
      end)
    end

    test "fails to transfer channel to a user not registered" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        founder = "founder"
        new_founder = "not_registered_user"
        user = insert(:user, identified_as: founder)

        insert(:registered_channel, name: channel_name, founder: founder)

        assert :ok = Transfer.handle(user, ["TRANSFER", channel_name, new_founder])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :The nickname \x02#{new_founder}\x02 is not registered.\r\n"}
        ])

        # Verify channel ownership didn't change
        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.founder == founder
      end)
    end
  end
end
