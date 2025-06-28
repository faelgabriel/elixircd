defmodule ElixIRCd.Services.Chanserv.DropTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Services.Chanserv.Drop

  describe "handle/2" do
    test "handles DROP command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "founder")

        assert :ok = Drop.handle(user, ["DROP"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02DROP\x02.\r\n"},
          {user.pid, ~r/ChanServ.*NOTICE.*Syntax: \x02DROP <channel>\x02.*/}
        ])
      end)
    end

    test "rejects DROP command when user is not identified" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: nil)

        assert :ok = Drop.handle(user, ["DROP", channel_name])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You must be identified with NickServ to use this command.\r\n"}
        ])
      end)
    end

    test "handles DROP command for channel not registered" do
      Memento.transaction!(fn ->
        channel_name = "#nonexistentchannel"
        user = insert(:user, identified_as: "founder")

        assert :ok = Drop.handle(user, ["DROP", channel_name])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#{channel_name}\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "rejects DROP command when user is not the founder" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        founder = "original_founder"
        user = insert(:user, identified_as: "not_founder")

        insert(:registered_channel, name: channel_name, founder: founder)

        assert :ok = Drop.handle(user, ["DROP", channel_name])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Access denied. You are not the founder of \x02#{channel_name}\x02.\r\n"}
        ])

        # Verify channel is still registered
        assert {:ok, _} = RegisteredChannels.get_by_name(channel_name)
      end)
    end

    test "successfully drops a registered channel" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        founder = "founder"
        user = insert(:user, identified_as: founder)

        insert(:registered_channel, name: channel_name, founder: founder)

        assert :ok = Drop.handle(user, ["DROP", channel_name])

        assert_sent_messages([
          {user.pid, ~r/ChanServ.*NOTICE.*Channel \x02#{channel_name}\x02 has been dropped/},
          {user.pid, ~r/ChanServ.*NOTICE.*All channel data and settings have been permanently deleted/}
        ])

        # Verify channel is no longer registered
        assert {:error, :registered_channel_not_found} = RegisteredChannels.get_by_name(channel_name)
      end)
    end
  end
end
