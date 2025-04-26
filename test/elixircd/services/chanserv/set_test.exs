defmodule ElixIRCd.Services.Chanserv.SetTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Services.Chanserv.Set
  alias ElixIRCd.Tables.RegisteredChannel.Settings

  describe "handle/2" do
    test "rejects commands from unidentified users" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: nil)

        assert :ok = Set.handle(user, ["SET", "#channel", "DESCRIPTION", "Test Description"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :You must be identified with NickServ to use this command.\r\n"}
        ])
      end)
    end

    test "rejects commands for non-registered channels" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "founder")
        channel_name = "#nonregistered"

        assert :ok = Set.handle(user, ["SET", channel_name, "DESCRIPTION", "Test Description"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel #{channel_name} is not registered.\r\n"}
        ])
      end)
    end

    test "rejects commands from non-founders" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        insert(:registered_channel, name: channel_name, founder: "real_founder")
        user = insert(:user, identified_as: "not_founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "DESCRIPTION", "Test Description"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Access denied. You are not the founder of #{channel_name}.\r\n"}
        ])
      end)
    end

    test "shows syntax help with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user, identified_as: "founder")

        assert :ok = Set.handle(user, ["SET"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Syntax: SET <channel> <option> [parameters]\r\n"},
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :For help, type: /msg ChanServ HELP SET\r\n"}
        ])
      end)
    end

    test "handles DESCRIPTION setting - set and show" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        description = "This is a test channel for important tests"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "DESCRIPTION", description])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2DESCRIPTION\2 for \2#{channel_name}\2 has been set to: \2#{description}\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.description == description

        assert :ok = Set.handle(user, ["SET", channel_name, "DESCRIPTION"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2DESCRIPTION\2 for \2#{channel_name}\2 is: \2#{description}\2\r\n"}
        ])
      end)
    end

    test "handles DESCRIPTION unset with empty value" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        description = "This is a test channel"
        user = insert(:user, identified_as: "founder")

        insert(:registered_channel,
          name: channel_name,
          founder: "founder",
          settings: %{Settings.new() | description: description}
        )

        assert :ok = Set.handle(user, ["SET", channel_name, "DESCRIPTION", ""])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2DESCRIPTION\2 for \2#{channel_name}\2 has been unset\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.description == nil
      end)
    end

    test "handles boolean setting GUARD" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "GUARD", "ON"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2GUARD\2 option for \2#{channel_name}\2 is now \2ON\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.guard == true

        assert :ok = Set.handle(user, ["SET", channel_name, "GUARD", "OFF"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2GUARD\2 option for \2#{channel_name}\2 is now \2OFF\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.guard == false

        assert :ok = Set.handle(user, ["SET", channel_name, "GUARD", "INVALID"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2INVALID\2 is not a valid setting for \2GUARD\2. Use \2ON\2 or \2OFF\2.\r\n"}
        ])

        assert :ok = Set.handle(user, ["SET", channel_name, "GUARD"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :\2Invalid\2 value. Use \2ON\2 or \2OFF\2.\r\n"}
        ])
      end)
    end

    test "handles EMAIL setting with validation" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        email = "test@example.com"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "EMAIL", email])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2EMAIL\2 for \2#{channel_name}\2 has been set to: \2#{email}\2\r\n"}
        ])

        assert :ok = Set.handle(user, ["SET", channel_name, "EMAIL"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2EMAIL\2 for \2#{channel_name}\2 is: \2#{email}\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.email == email

        assert :ok = Set.handle(user, ["SET", channel_name, "EMAIL", "invalid-email"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2invalid-email\2 is not a valid email address.\r\n"}
        ])

        assert :ok = Set.handle(user, ["SET", channel_name, "EMAIL", "OFF"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2EMAIL\2 for \2#{channel_name}\2 has been unset\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.email == nil
      end)
    end

    test "handles TOPICLOCK setting" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "TOPICLOCK", "ON"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2TOPICLOCK\2 option for \2#{channel_name}\2 is now \2ON\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.topiclock == true

        assert :ok = Set.handle(user, ["SET", channel_name, "TOPICLOCK"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2TOPICLOCK\2 for \2#{channel_name}\2 is set to: \2ON\2\r\n"}
        ])

        assert :ok = Set.handle(user, ["SET", channel_name, "TOPICLOCK", "OFF"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2TOPICLOCK\2 option for \2#{channel_name}\2 is now \2OFF\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.topiclock == false

        assert :ok = Set.handle(user, ["SET", channel_name, "TOPICLOCK", "INVALID"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2INVALID\2 is not a valid setting for \2TOPICLOCK\2. Use \2ON\2 or \2OFF\2.\r\n"}
        ])
      end)
    end

    test "handles KEEPTOPIC setting" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "KEEPTOPIC", "ON"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2KEEPTOPIC\2 option for \2#{channel_name}\2 is now \2ON\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.keeptopic == true

        assert :ok = Set.handle(user, ["SET", channel_name, "KEEPTOPIC", "OFF"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2KEEPTOPIC\2 option for \2#{channel_name}\2 is now \2OFF\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.keeptopic == false

        assert :ok = Set.handle(user, ["SET", channel_name, "KEEPTOPIC", "INVALID"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2INVALID\2 is not a valid setting for \2KEEPTOPIC\2. Use \2ON\2 or \2OFF\2.\r\n"}
        ])
      end)
    end

    test "handles PRIVATE setting" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "PRIVATE", "ON"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2PRIVATE\2 option for \2#{channel_name}\2 is now \2ON\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.private == true

        assert :ok = Set.handle(user, ["SET", channel_name, "PRIVATE", "OFF"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2PRIVATE\2 option for \2#{channel_name}\2 is now \2OFF\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.private == false
      end)
    end

    test "handles RESTRICTED setting" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "RESTRICTED", "ON"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2RESTRICTED\2 option for \2#{channel_name}\2 is now \2ON\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.restricted == true

        assert :ok = Set.handle(user, ["SET", channel_name, "RESTRICTED", "OFF"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2RESTRICTED\2 option for \2#{channel_name}\2 is now \2OFF\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.restricted == false
      end)
    end

    test "handles FANTASY setting" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "FANTASY", "ON"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2FANTASY\2 option for \2#{channel_name}\2 is now \2ON\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.fantasy == true

        assert :ok = Set.handle(user, ["SET", channel_name, "FANTASY", "OFF"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2FANTASY\2 option for \2#{channel_name}\2 is now \2OFF\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.fantasy == false
      end)
    end

    test "handles URL setting" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        url = "https://example.com/irc-channel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "URL", url])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2URL\2 for \2#{channel_name}\2 has been set to: \2#{url}\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.url == url

        assert :ok = Set.handle(user, ["SET", channel_name, "URL"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2URL\2 for \2#{channel_name}\2 is: \2#{url}\2\r\n"}
        ])

        assert :ok = Set.handle(user, ["SET", channel_name, "URL", "OFF"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2URL\2 for \2#{channel_name}\2 has been unset\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.url == nil

        assert :ok = Set.handle(user, ["SET", channel_name, "URL", "one", "two"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Syntax: SET <channel> URL <url> or SET <channel> URL OFF to clear\r\n"}
        ])
      end)
    end

    test "handles ENTRYMSG setting" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        entrymsg = "Welcome to #{channel_name}! Please read the rules."
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok =
                 Set.handle(user, [
                   "SET",
                   channel_name,
                   "ENTRYMSG",
                   "Welcome",
                   "to",
                   "#{channel_name}!",
                   "Please",
                   "read",
                   "the",
                   "rules."
                 ])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2ENTRYMSG\2 for \2#{channel_name}\2 has been set to: \2#{entrymsg}\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.entrymsg == entrymsg

        assert :ok = Set.handle(user, ["SET", channel_name, "ENTRYMSG"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2ENTRYMSG\2 for \2#{channel_name}\2 is: \2#{entrymsg}\2\r\n"}
        ])

        assert :ok = Set.handle(user, ["SET", channel_name, "ENTRYMSG", "OFF"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2ENTRYMSG\2 for \2#{channel_name}\2 has been unset\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.entrymsg == nil
      end)
    end

    test "handles OPNOTICE setting" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "OPNOTICE", "ON"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2OPNOTICE\2 option for \2#{channel_name}\2 is now \2ON\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.opnotice == true

        assert :ok = Set.handle(user, ["SET", channel_name, "OPNOTICE", "OFF"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2OPNOTICE\2 option for \2#{channel_name}\2 is now \2OFF\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.opnotice == false
      end)
    end

    test "handles PEACE setting" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "PEACE", "ON"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2PEACE\2 option for \2#{channel_name}\2 is now \2ON\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.peace == true

        assert :ok = Set.handle(user, ["SET", channel_name, "PEACE", "OFF"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2PEACE\2 option for \2#{channel_name}\2 is now \2OFF\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.peace == false
      end)
    end

    test "handles SECURE setting" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "SECURE", "ON"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2SECURE\2 option for \2#{channel_name}\2 is now \2ON\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.secure == true

        assert :ok = Set.handle(user, ["SET", channel_name, "SECURE", "OFF"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2SECURE\2 option for \2#{channel_name}\2 is now \2OFF\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.secure == false
      end)
    end

    test "handles DESC as alias for DESCRIPTION" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        description = "This is a test channel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "DESC", description])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2DESCRIPTION\2 for \2#{channel_name}\2 has been set to: \2#{description}\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.description == description
      end)
    end

    test "handles invalid values for boolean settings" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        for setting <- [
              "RESTRICTED",
              "FANTASY",
              "OPNOTICE",
              "PEACE",
              "SECURE",
              "PRIVATE",
              "GUARD",
              "KEEPTOPIC",
              "TOPICLOCK"
            ] do
          assert :ok = Set.handle(user, ["SET", channel_name, setting, "YES"])

          assert_sent_messages([
            {user.pid,
             ":ChanServ!service@irc.test NOTICE #{user.nick} :\2YES\2 is not a valid setting for \2#{setting}\2. Use \2ON\2 or \2OFF\2.\r\n"}
          ])

          assert :ok = Set.handle(user, ["SET", channel_name, setting, "1"])

          assert_sent_messages([
            {user.pid,
             ":ChanServ!service@irc.test NOTICE #{user.nick} :\21\2 is not a valid setting for \2#{setting}\2. Use \2ON\2 or \2OFF\2.\r\n"}
          ])
        end
      end)
    end

    test "handles unknown setting command" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "NONEXISTENTSETTING", "value"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Unknown setting: \2NONEXISTENTSETTING\2\r\n"},
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :For a list of settings, type: /msg ChanServ HELP SET\r\n"}
        ])
      end)
    end

    test "handles missing parameters for various boolean settings" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        for setting <- ["KEEPTOPIC", "PRIVATE", "RESTRICTED", "FANTASY", "OPNOTICE", "PEACE", "SECURE"] do
          assert :ok = Set.handle(user, ["SET", channel_name, setting])

          assert_sent_messages([
            {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :\2Invalid\2 value. Use \2ON\2 or \2OFF\2.\r\n"}
          ])
        end
      end)
    end

    test "shows message when no description is set" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "DESCRIPTION"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :No \2DESCRIPTION\2 is set for \2#{channel_name}\2.\r\n"}
        ])
      end)
    end

    test "shows message when no URL is set" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "URL"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :No \2URL\2 is set for \2#{channel_name}\2.\r\n"}
        ])
      end)
    end

    test "shows message when no email is set" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "EMAIL"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :No \2EMAIL\2 is set for \2#{channel_name}\2.\r\n"}
        ])
      end)
    end

    test "shows syntax help for email with invalid parameters" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "EMAIL", "one", "two"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Syntax: SET <channel> EMAIL <email> or SET <channel> EMAIL OFF to clear\r\n"}
        ])
      end)
    end

    test "shows message when no entry message is set" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "ENTRYMSG"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :No \2ENTRYMSG\2 is set for \2#{channel_name}\2.\r\n"}
        ])
      end)
    end

    test "unsets entry message when set to empty string" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        entrymsg = "Welcome to the channel!"

        insert(:registered_channel,
          name: channel_name,
          founder: "founder",
          settings: %{Settings.new() | entrymsg: entrymsg}
        )

        assert :ok = Set.handle(user, ["SET", channel_name, "ENTRYMSG", ""])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2ENTRYMSG\2 for \2#{channel_name}\2 has been unset\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.settings.entrymsg == nil
      end)
    end

    test "handles TOPICLOCK with various settings and displays" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "TOPICLOCK"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2TOPICLOCK\2 for \2#{channel_name}\2 is set to: \2OFF\2\r\n"}
        ])
      end)

      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "TOPICLOCK", "one", "two"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :\2Invalid\2 value. Use \2ON\2 or \2OFF\2.\r\n"}
        ])
      end)
    end

    test "handles SUCCESSOR setting - set and show" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        successor = "co_founder"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")
        insert(:registered_nick, nickname: successor)

        assert :ok = Set.handle(user, ["SET", channel_name, "SUCCESSOR", successor])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2SUCCESSOR\2 for \2#{channel_name}\2 has been set to: \2#{successor}\2\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.successor == successor

        assert :ok = Set.handle(user, ["SET", channel_name, "SUCCESSOR"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2SUCCESSOR\2 for \2#{channel_name}\2 is: \2#{successor}\2\r\n"}
        ])
      end)
    end

    test "handles SUCCESSOR with unregistered nickname" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        non_existent_nick = "non_existent_nick"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "SUCCESSOR", non_existent_nick])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Cannot set successor: \2#{non_existent_nick}\2 is not a registered nickname.\r\n"}
        ])
      end)
    end

    test "handles SUCCESSOR OFF command" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        successor = "co_founder"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder", successor: successor)

        assert :ok = Set.handle(user, ["SET", channel_name, "SUCCESSOR", "OFF"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :\2SUCCESSOR\2 for \2#{channel_name}\2 has been unset.\r\n"}
        ])

        {:ok, channel} = RegisteredChannels.get_by_name(channel_name)
        assert channel.successor == nil
      end)
    end

    test "shows message when no successor is set" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "SUCCESSOR"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :No \2SUCCESSOR\2 is set for \2#{channel_name}\2.\r\n"}
        ])
      end)
    end

    test "shows syntax help for successor with invalid parameters" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        user = insert(:user, identified_as: "founder")
        insert(:registered_channel, name: channel_name, founder: "founder")

        assert :ok = Set.handle(user, ["SET", channel_name, "SUCCESSOR", "nick1", "nick2"])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Syntax: SET <channel> SUCCESSOR <nickname> or SET <channel> SUCCESSOR OFF to clear\r\n"}
        ])
      end)
    end
  end
end
