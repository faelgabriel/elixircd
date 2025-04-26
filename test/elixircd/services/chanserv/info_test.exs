defmodule ElixIRCd.Services.Chanserv.InfoTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Chanserv.Info
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.RegisteredChannel

  describe "handle/2" do
    test "handles INFO command with insufficient parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)

        assert :ok = Info.handle(user, ["INFO"])

        assert_sent_messages([
          {user.pid, ":ChanServ!service@irc.test NOTICE #{user.nick} :Insufficient parameters for \x02INFO\x02.\r\n"},
          {user.pid, ~r/ChanServ.*NOTICE.*Syntax: \x02INFO <channel> \[ALL\]\x02.*/}
        ])
      end)
    end

    test "handles INFO command for unregistered channel" do
      Memento.transaction!(fn ->
        channel_name = "#nonexistentchannel"
        user = insert(:user)

        assert :ok = Info.handle(user, ["INFO", channel_name])

        assert_sent_messages([
          {user.pid,
           ":ChanServ!service@irc.test NOTICE #{user.nick} :Channel \x02#{channel_name}\x02 is not registered.\r\n"}
        ])
      end)
    end

    test "displays basic channel info for non-founder" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        founder = "founder"
        description = "Test channel description"
        user = insert(:user, identified_as: "not_founder")

        settings = RegisteredChannel.Settings.new(%{description: description})

        topic = %Channel.Topic{
          text: "Channel topic",
          setter: "someone",
          set_at: DateTime.from_unix!(1_609_459_200)
        }

        insert(:registered_channel,
          name: channel_name,
          founder: founder,
          settings: settings,
          created_at: DateTime.from_unix!(1_609_459_200),
          last_used_at: DateTime.from_unix!(1_609_459_200),
          topic: topic
        )

        assert :ok = Info.handle(user, ["INFO", channel_name])

        # Verify only basic channel info is displayed
        assert_sent_messages([
          {user.pid, ~r/ChanServ.*NOTICE.*Information for channel \x02#{channel_name}\x02:/},
          {user.pid, ~r/ChanServ.*NOTICE.*Founder: #{founder}/},
          {user.pid, ~r/ChanServ.*NOTICE.*Description: #{description}/},
          {user.pid, ~r/ChanServ.*NOTICE.*Registered: 2021-01-01 00:00:00/},
          {user.pid, ~r/ChanServ.*NOTICE.*Last used: 2021-01-01 00:00:00/},
          {user.pid, ~r/ChanServ.*NOTICE.*\*\*\*\*\* End of Info \*\*\*\*\*/}
        ])

        # Make sure no privileged messages were sent
        all_messages = Agent.get(@agent_name, &Enum.reverse/1)

        assert Enum.all?(all_messages, fn {pid, msg} ->
                 pid != user.pid || (!String.contains?(msg, "Flags:") && !String.contains?(msg, "Mode lock:"))
               end)
      end)
    end

    test "displays detailed channel info for founder" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        founder = "founder"
        description = "Test channel description"
        user = insert(:user, identified_as: founder)

        settings =
          RegisteredChannel.Settings.new(%{
            description: description,
            guard: true,
            keeptopic: true,
            restricted: true,
            fantasy: true,
            opnotice: true,
            entrymsg: "Welcome to the channel!",
            mlock: "+nt"
          })

        topic = %Channel.Topic{
          text: "Channel topic",
          setter: "someone",
          set_at: DateTime.from_unix!(1_609_459_200)
        }

        insert(:registered_channel,
          name: channel_name,
          founder: founder,
          settings: settings,
          last_used_at: DateTime.from_unix!(1_609_459_200),
          created_at: DateTime.from_unix!(1_609_459_200),
          topic: topic
        )

        assert :ok = Info.handle(user, ["INFO", channel_name])

        assert_sent_messages([
          # First verify just the basic info messages
          {user.pid, ~r/ChanServ.*NOTICE.*Information for channel \x02#{channel_name}\x02:/},
          {user.pid, ~r/ChanServ.*NOTICE.*Founder: #{founder}/},
          {user.pid, ~r/ChanServ.*NOTICE.*Description: #{description}/},
          {user.pid, ~r/ChanServ.*NOTICE.*Registered: 2021-01-01 00:00:00/},
          {user.pid, ~r/ChanServ.*NOTICE.*Last used: 2021-01-01 00:00:00/},
          # Then separately verify the privileged info messages
          {user.pid, ~r/ChanServ.*NOTICE.*Flags: FANTASY, GUARD, KEEPTOPIC, OPNOTICE, RESTRICTED/},
          {user.pid, ~r/ChanServ.*NOTICE.*Mode lock: \+nt/},
          {user.pid, ~r/ChanServ.*NOTICE.*Entry message: Welcome to the channel!/},
          {user.pid, ~r/ChanServ.*NOTICE.*Last topic: Channel topic/},
          {user.pid, ~r/ChanServ.*NOTICE.*Topic set by: someone \(2021-01-01 00:00:00\)/},
          {user.pid, ~r/ChanServ.*NOTICE.*\*\*\*\*\* End of Info \*\*\*\*\*/}
        ])
      end)
    end

    test "displays ALL info when founder uses ALL parameter" do
      Memento.transaction!(fn ->
        channel_name = "#testchannel"
        founder = "founder"
        description = "Test channel description"
        user = insert(:user, identified_as: founder)

        settings =
          RegisteredChannel.Settings.new(%{
            description: description,
            guard: true,
            url: "https://example.com",
            email: "contact@example.com",
            mlock: "+nt"
          })

        insert(:registered_channel,
          name: channel_name,
          founder: founder,
          settings: settings,
          created_at: DateTime.from_unix!(1_609_459_200),
          last_used_at: DateTime.from_unix!(1_609_459_200)
        )

        assert :ok = Info.handle(user, ["INFO", channel_name, "ALL"])

        assert_sent_messages([
          # Basic info messages
          {user.pid, ~r/ChanServ.*NOTICE.*Information for channel \x02#{channel_name}\x02:/},
          {user.pid, ~r/ChanServ.*NOTICE.*Founder: #{founder}/},
          {user.pid, ~r/ChanServ.*NOTICE.*Description: #{description}/},
          {user.pid, ~r/ChanServ.*NOTICE.*Registered: 2021-01-01 00:00:00/},
          {user.pid, ~r/ChanServ.*NOTICE.*Last used: 2021-01-01 00:00:00/},
          # Privileged info messages
          {user.pid, ~r/ChanServ.*NOTICE.*Flags: FANTASY, GUARD, KEEPTOPIC, OPNOTICE/},
          {user.pid, ~r/ChanServ.*NOTICE.*Mode lock: \+nt/},
          {user.pid, ~r/ChanServ.*NOTICE.*Entry message: \(none\)/},
          {user.pid, ~r/ChanServ.*NOTICE.*Last topic: \(none\)/},
          # All info messages
          {user.pid, ~r/ChanServ.*NOTICE.*URL: https:\/\/example.com/},
          {user.pid, ~r/ChanServ.*NOTICE.*Email: contact@example.com/},
          {user.pid, ~r/ChanServ.*NOTICE.*Successor: \(none\)/},
          {user.pid, ~r/ChanServ.*NOTICE.*Expires: 2021-04-01 00:00:00/},
          {user.pid, ~r/ChanServ.*NOTICE.*\*\*\*\*\* End of Info \*\*\*\*/}
        ])
      end)
    end

    test "handles case insensitive channel names" do
      Memento.transaction!(fn ->
        channel_name = "#TestChannel"
        lowercase_name = String.downcase(channel_name)
        founder = "founder"
        user = insert(:user)

        settings = RegisteredChannel.Settings.new()

        created_at = DateTime.from_unix!(1_609_459_200)
        last_used_at = DateTime.from_unix!(1_609_459_200)

        insert(:registered_channel,
          name: lowercase_name,
          founder: founder,
          settings: settings,
          created_at: created_at,
          last_used_at: last_used_at
        )

        assert :ok = Info.handle(user, ["INFO", channel_name])

        assert_sent_messages([
          {user.pid, ~r/ChanServ.*NOTICE.*Information for channel \x02#{lowercase_name}\x02:/},
          {user.pid, ~r/ChanServ.*NOTICE.*Founder: #{founder}/},
          {user.pid, ~r/ChanServ.*NOTICE.*Description: \(none\)/},
          {user.pid, ~r/ChanServ.*NOTICE.*Registered: 2021-01-01 00:00:00/},
          {user.pid, ~r/ChanServ.*NOTICE.*Last used: 2021-01-01 00:00:00/},
          {user.pid, ~r/ChanServ.*NOTICE.*\*\*\*\*\* End of Info \*\*\*\*\*/}
        ])
      end)
    end
  end
end
