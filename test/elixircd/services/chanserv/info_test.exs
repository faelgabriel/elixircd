defmodule ElixIRCd.Services.Chanserv.InfoTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Services.Chanserv.Info
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.RegisteredChannel

  # 2021-01-01 00:00:00
  @timestamp_2021_01_01 DateTime.from_unix!(1_609_459_200)

  describe "handle/2 basic functionality" do
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

    test "handles INFO command for channel not registered" do
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
  end

  describe "handle/2 access level tests" do
    test "displays basic channel info for non-founder" do
      Memento.transaction!(fn ->
        description = "Test channel description"
        user = insert(:user, identified_as: "not_founder")

        topic = %Channel.Topic{
          text: "Channel topic",
          setter: "someone",
          set_at: @timestamp_2021_01_01
        }

        channel =
          create_test_channel(
            settings: [description: description],
            topic: topic
          )

        assert :ok = Info.handle(user, ["INFO", channel.name])

        # Verify only basic channel info is displayed
        assert_sent_messages([
          {user.pid, ~r/ChanServ.*NOTICE.*Information for channel \x02#{channel.name}\x02:/},
          {user.pid, ~r/ChanServ.*NOTICE.*Founder: #{channel.founder}/},
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
        description = "Test channel description"
        founder = "founder"
        user = insert(:user, identified_as: founder)

        topic = %Channel.Topic{
          text: "Channel topic",
          setter: "someone",
          set_at: @timestamp_2021_01_01
        }

        channel =
          create_test_channel(
            founder: founder,
            settings: [
              description: description,
              guard: true,
              keeptopic: true,
              restricted: true,
              fantasy: true,
              opnotice: true,
              entrymsg: "Welcome to the channel!",
              mlock: "+nt"
            ],
            topic: topic
          )

        assert :ok = Info.handle(user, ["INFO", channel.name])

        assert_sent_messages([
          # First verify just the basic info messages
          {user.pid, ~r/ChanServ.*NOTICE.*Information for channel \x02#{channel.name}\x02:/},
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
  end

  describe "handle/2 content display tests" do
    test "displays ALL info when founder uses ALL parameter" do
      Memento.transaction!(fn ->
        description = "Test channel description"
        founder = "founder"
        user = insert(:user, identified_as: founder)

        channel =
          create_test_channel(
            founder: founder,
            settings: [
              description: description,
              guard: true,
              url: "https://example.com",
              email: "contact@example.com",
              mlock: "+nt"
            ]
          )

        assert :ok = Info.handle(user, ["INFO", channel.name, "ALL"])

        assert_sent_messages([
          # Basic info messages
          {user.pid, ~r/ChanServ.*NOTICE.*Information for channel \x02#{channel.name}\x02:/},
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
          {user.pid, ~r/ChanServ.*NOTICE.*\*\*\*\*\* End of Info \*\*\*\*\*/}
        ])
      end)
    end

    test "displays successor in ALL info when set" do
      Memento.transaction!(fn ->
        founder = "founder"
        successor = "successor_nick"
        user = insert(:user, identified_as: founder)

        channel =
          create_test_channel(
            founder: founder,
            successor: successor
          )

        assert :ok = Info.handle(user, ["INFO", channel.name, "ALL"])

        assert_sent_messages([
          {user.pid, ~r/ChanServ.*NOTICE.*Information for channel \x02#{channel.name}\x02:/},
          {user.pid, ~r/ChanServ.*NOTICE.*Founder: #{founder}/},
          {user.pid, ~r/ChanServ.*NOTICE.*Description: \(none\)/},
          {user.pid, ~r/ChanServ.*NOTICE.*Registered: 2021-01-01 00:00:00/},
          {user.pid, ~r/ChanServ.*NOTICE.*Last used: 2021-01-01 00:00:00/},
          {user.pid, ~r/ChanServ.*NOTICE.*Flags: /},
          {user.pid, ~r/ChanServ.*NOTICE.*Mode lock: /},
          {user.pid, ~r/ChanServ.*NOTICE.*Entry message: /},
          {user.pid, ~r/ChanServ.*NOTICE.*Last topic: /},
          {user.pid, ~r/ChanServ.*NOTICE.*URL: /},
          {user.pid, ~r/ChanServ.*NOTICE.*Email: /},
          {user.pid, ~r/ChanServ.*NOTICE.*Successor: #{successor}/},
          {user.pid, ~r/ChanServ.*NOTICE.*Expires: /},
          {user.pid, ~r/ChanServ.*NOTICE.*\*\*\*\*\* End of Info \*\*\*\*\*/}
        ])
      end)
    end

    test "displays privileged info with no topic" do
      Memento.transaction!(fn ->
        founder = "founder"
        user = insert(:user, identified_as: founder)

        channel =
          create_test_channel(
            founder: founder,
            settings: [
              mlock: "+nt",
              entrymsg: "Welcome to the channel!"
            ],
            topic: nil
          )

        assert :ok = Info.handle(user, ["INFO", channel.name])

        # Verify all messages including the "Last topic: (none)" message
        assert_sent_messages([
          {user.pid, ~r/ChanServ.*NOTICE.*Information for channel \x02#{channel.name}\x02:/},
          {user.pid, ~r/ChanServ.*NOTICE.*Founder: #{founder}/},
          {user.pid, ~r/ChanServ.*NOTICE.*Description: \(none\)/},
          {user.pid, ~r/ChanServ.*NOTICE.*Registered: 2021-01-01 00:00:00/},
          {user.pid, ~r/ChanServ.*NOTICE.*Last used: 2021-01-01 00:00:00/},
          {user.pid, ~r/ChanServ.*NOTICE.*Flags: /},
          {user.pid, ~r/ChanServ.*NOTICE.*Mode lock: \+nt/},
          {user.pid, ~r/ChanServ.*NOTICE.*Entry message: Welcome to the channel!/},
          {user.pid, ~r/ChanServ.*NOTICE.*Last topic: \(none\)/},
          {user.pid, ~r/ChanServ.*NOTICE.*\*\*\*\*\* End of Info \*\*\*\*\*/}
        ])
      end)
    end

    test "displays (none) when no flags are set" do
      Memento.transaction!(fn ->
        founder = "founder"
        user = insert(:user, identified_as: founder)

        channel =
          create_test_channel(
            founder: founder,
            settings: [
              guard: false,
              keeptopic: false,
              private: false,
              restricted: false,
              fantasy: false,
              opnotice: false,
              peace: false,
              secure: false,
              topiclock: false
            ]
          )

        assert :ok = Info.handle(user, ["INFO", channel.name])

        assert_sent_messages([
          {user.pid, ~r/ChanServ.*NOTICE.*Information for channel \x02#{channel.name}\x02:/},
          {user.pid, ~r/ChanServ.*NOTICE.*Founder: #{founder}/},
          {user.pid, ~r/ChanServ.*NOTICE.*Description: \(none\)/},
          {user.pid, ~r/ChanServ.*NOTICE.*Registered: 2021-01-01 00:00:00/},
          {user.pid, ~r/ChanServ.*NOTICE.*Last used: 2021-01-01 00:00:00/},
          {user.pid, ~r/ChanServ.*NOTICE.*Flags: \(none\)/},
          {user.pid, ~r/ChanServ.*NOTICE.*Mode lock: \(none\)/},
          {user.pid, ~r/ChanServ.*NOTICE.*Entry message: \(none\)/},
          {user.pid, ~r/ChanServ.*NOTICE.*Last topic: \(none\)/},
          {user.pid, ~r/ChanServ.*NOTICE.*\*\*\*\*\* End of Info \*\*\*\*\*/}
        ])
      end)
    end
  end

  # Helper function to create a test channel
  defp create_test_channel(opts) do
    channel_name = opts[:name] || "#testchannel"
    founder = opts[:founder] || "founder"

    settings_params = Map.new(opts[:settings] || [])
    settings = RegisteredChannel.Settings.new(settings_params)

    channel_params = %{
      name: String.downcase(channel_name),
      founder: founder,
      settings: settings,
      created_at: @timestamp_2021_01_01,
      last_used_at: @timestamp_2021_01_01,
      topic: opts[:topic],
      successor: opts[:successor]
    }

    insert(:registered_channel, channel_params)

    channel_params
  end
end
