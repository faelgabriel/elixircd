defmodule ElixIRCd.Commands.WhoisTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Whois
  alias ElixIRCd.Message
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.Directory
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Utils.CaseMapping

  describe "handle/2" do
    test "WHOIS reports a remote user's replicated identity and visible channel" do
      nick_table = Directory.create()
      channel_table = ChannelDirectory.create()
      uid = String.duplicate("a", 32)

      remote_user =
        build(:user,
          nick: "Remote",
          ident: "~remote",
          hostname: "real.example",
          cloaked_hostname: "cloak.example",
          modes: [:r, :x, :B],
          identified_as: "account",
          away_message: "stepped away"
        )

      payload = UserPayload.from_local(remote_user, uid)
      old = Replica.new()

      current = %{
        old
        | users: %{{"east.example", uid} => payload},
          nick_keys: %{CaseMapping.normalize("Remote") => {"east.example", uid}}
      }

      Directory.sync(nick_table, old, current)

      channel_view = fn name, modes, status ->
        %{
          channel: %{"name" => name, "modes" => Enum.map(modes, &%{"name" => &1})},
          remote_members: [%{origin: "east.example", member: %{"uid" => uid}, effective_modes: status}]
        }
      end

      ChannelDirectory.sync(channel_table, %{}, %{
        CaseMapping.normalize("#public") => channel_view.("#public", [], ["o"]),
        CaseMapping.normalize("#secret") => channel_view.("#secret", ["s"], [])
      })

      Memento.transaction!(fn ->
        viewer = insert(:user, nick: "Viewer")
        assert :ok = Whois.handle(viewer, %Message{command: "WHOIS", params: ["Remote"]})
        assert_sent_message_contains(viewer.pid, ~r/ 311 Viewer Remote ~remote cloak\.example \* /)
        assert_sent_message_contains(viewer.pid, ~r/ 307 Viewer Remote /)
        assert_sent_message_contains(viewer.pid, ~r/ 330 Viewer Remote account /)
        assert_sent_message_contains(viewer.pid, ~r/ 335 Viewer Remote /)
        assert_sent_message_contains(viewer.pid, ":irc.test 319 Viewer Remote :@#public\r\n")
        assert_sent_messages_count_containing(viewer.pid, "#secret", 0)
        assert_sent_message_contains(viewer.pid, ~r/ 312 Viewer Remote east\.example /)
        assert_sent_message_contains(viewer.pid, ~r/ 301 Viewer Remote :stepped away/)
        assert_sent_message_contains(viewer.pid, ~r/ 318 Viewer Remote /)
        assert_sent_messages_count_containing(viewer.pid, ~r/ 317 /, 0)

        assert :ok = Whois.handle(viewer, %Message{command: "WHOIS", params: ["east.example", "Remote"]})
        assert_sent_message_contains(viewer.pid, ~r/ 311 Viewer Remote /)

        operator = insert(:user, nick: "Oper", modes: [:o])
        assert :ok = Whois.handle(operator, %Message{command: "WHOIS", params: ["Remote"]})
        assert_sent_message_contains(operator.pid, ~r/ 311 Oper Remote ~remote real\.example \* /)
        assert_sent_message_contains(operator.pid, ~r/ 338 Oper Remote real\.example /)
        assert_sent_message_contains(operator.pid, ~r/ 379 Oper Remote :is using modes \+Brx/)
      end)
    end

    for {modes, wire_modes} <- [{[], ""}, {[:w, :i], "iw"}, {[:s, :o, :H], "Hos"}] do
      test "WHOIS shows own modes #{inspect(modes)} without capability negotiation" do
        Memento.transaction!(fn ->
          user = insert(:user, modes: unquote(modes), capabilities: [])
          assert :ok = Whois.handle(user, %Message{command: "WHOIS", params: [user.nick]})
          modes = "+" <> unquote(wire_modes)
          assert_sent_message_contains(user.pid, ":irc.test 379 #{user.nick} #{user.nick} :is using modes #{modes}\r\n")
          assert_sent_messages_count_containing(user.pid, ~r/ 379 /, 1)
          assert_sent_message_contains(user.pid, ~r/ 318 #{user.nick} #{user.nick} /)
        end)
      end
    end

    test "WHOIS shows all target modes to IRCops" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: [:o])
        target = insert(:user, modes: [:w, :s, :o, :H, :i])
        assert :ok = Whois.handle(user, %Message{command: "WHOIS", params: [target.nick]})
        assert_sent_message_contains(user.pid, ":irc.test 379 #{user.nick} #{target.nick} :is using modes +Hiosw\r\n")
        assert_sent_messages_count_containing(user.pid, ~r/ 379 /, 1)
      end)
    end

    test "WHOIS does not reveal modes to channel operators even with the same account" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: [], identified_as: "shared-account")
        target = insert(:user, modes: [:i, :w], identified_as: "shared-account")
        channel = insert(:channel)
        insert(:user_channel, user: user, channel: channel, modes: [:o])
        insert(:user_channel, user: target, channel: channel)
        assert :ok = Whois.handle(user, %Message{command: "WHOIS", params: [target.nick]})
        assert_sent_message_contains(user.pid, ~r/ 311 #{user.nick} #{target.nick} /)
        assert_sent_messages_count_containing(user.pid, ~r/ 379 /, 0)
      end)
    end

    test "handles WHOIS command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "WHOIS", params: ["#anything"]}

        assert :ok = Whois.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles WHOIS command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHOIS", params: []}

        assert :ok = Whois.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} WHOIS :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles WHOIS command with inexistent user nick" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "WHOIS", params: ["invalid.nick"]}

        assert :ok = Whois.handle(user, message)

        assert_no_user_whois_message(user, "invalid.nick")
      end)
    end

    test "handles WHOIS command with user nick target" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick")
        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_user_whois_message(user, target_user, channel)
      end)
    end

    test "handles WHOIS command with non-invisible target user (covers visibility check)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        # Explicitly create a target user without 'i' mode (non-invisible)
        target_user = insert(:user, nick: "target_nick", modes: [])
        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_user_whois_message(user, target_user, channel)
      end)
    end

    test "shows all negotiated membership prefixes in rank order" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["multi-prefix"])
        target_user = insert(:user, nick: "multi_prefix_target")
        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel, modes: [:o])

        assert :ok = Whois.handle(user, %Message{command: "WHOIS", params: [target_user.nick]})
        assert_sent_message_contains(user.pid, ":irc.test 319 #{user.nick} #{target_user.nick} :@#{channel.name}\r\n")
      end)
    end

    test "handles WHOIS command with orphaned channel reference (edge case)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick")
        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel)

        # Delete the channel after creating the relationship to simulate orphaned reference
        Memento.Query.delete_record(channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        # Should still show the user but with no 319 channel list
        assert_sent_messages([
          {user.pid, ":irc.test 311 #{user.nick} #{target_user.nick} #{user.ident} hostname * :realname\r\n"},
          {user.pid, ":irc.test 312 #{user.nick} #{target_user.nick} irc.test :Elixir IRC daemon\r\n"},
          {user.pid, ~r/^:irc\.test 317 #{user.nick} #{target_user.nick} \d+ \d+ :seconds idle, signon time\r\n$/},
          {user.pid, ":irc.test 318 #{user.nick} #{target_user.nick} :End of /WHOIS list.\r\n"}
        ])
      end)
    end

    test "handles WHOIS command with secret channel where user is not a member" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick")

        # Create a secret channel
        secret_channel = insert(:channel, modes: [:s])
        public_channel = insert(:channel, modes: [])

        # Target user is in both channels, user is only in public channel
        insert(:user_channel, user: target_user, channel: secret_channel)
        insert(:user_channel, user: target_user, channel: public_channel)
        insert(:user_channel, user: user, channel: public_channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        # Should only show the public channel, not the secret one
        assert_sent_messages([
          {user.pid, ":irc.test 311 #{user.nick} #{target_user.nick} #{user.ident} hostname * :realname\r\n"},
          {user.pid, ":irc.test 319 #{user.nick} #{target_user.nick} :#{public_channel.name}\r\n"},
          {user.pid, ":irc.test 312 #{user.nick} #{target_user.nick} irc.test :Elixir IRC daemon\r\n"},
          {user.pid, ~r/^:irc\.test 317 #{user.nick} #{target_user.nick} \d+ \d+ :seconds idle, signon time\r\n$/},
          {user.pid, ":irc.test 318 #{user.nick} #{target_user.nick} :End of /WHOIS list.\r\n"}
        ])
      end)
    end

    test "handles WHOIS command with user nick target, invisible target user and user does not share channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick", modes: [:i])

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_user_whois_message(user, target_user, nil)
      end)
    end

    for viewer_oper? <- [false, true], shared? <- [false, true] do
      test "WHOIS +H with viewer oper=#{viewer_oper?}, shared=#{shared?}" do
        Memento.transaction!(fn ->
          user = insert(:user, modes: if(unquote(viewer_oper?), do: [:o], else: []))
          target = insert(:user, nick: "hidden", modes: [:o, :H, :i])

          if unquote(shared?) do
            channel = insert(:channel)
            insert(:user_channel, user: user, channel: channel)
            insert(:user_channel, user: target, channel: channel)
          end

          assert :ok = Whois.handle(user, %Message{command: "WHOIS", params: [target.nick]})
          assert_sent_messages_count_containing(user.pid, ~r/ 311 /, 1)
          assert_sent_messages_count_containing(user.pid, ~r/ 401 /, 0)
          assert_sent_messages_count_containing(user.pid, ~r/ 313 /, if(unquote(viewer_oper?), do: 1, else: 0))
        end)
      end
    end

    test "WHOIS shows +H users without disclosing their operator status" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "hidden_nick", modes: [:o, :H])

        message = %Message{command: "WHOIS", params: ["hidden_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_user_whois_message(user, target_user, nil)
      end)
    end

    test "handles WHOIS command hiding private channels from non-members" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick")

        private_channel = insert(:channel, modes: [:p])
        public_channel = insert(:channel, modes: [])

        insert(:user_channel, user: target_user, channel: private_channel)
        insert(:user_channel, user: target_user, channel: public_channel)
        insert(:user_channel, user: user, channel: public_channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 311 #{user.nick} #{target_user.nick} #{user.ident} hostname * :realname\r\n"},
          {user.pid, ":irc.test 319 #{user.nick} #{target_user.nick} :#{public_channel.name}\r\n"},
          {user.pid, ":irc.test 312 #{user.nick} #{target_user.nick} irc.test :Elixir IRC daemon\r\n"},
          {user.pid, ~r/^:irc\.test 317 #{user.nick} #{target_user.nick} \d+ \d+ :seconds idle, signon time\r\n$/},
          {user.pid, ":irc.test 318 #{user.nick} #{target_user.nick} :End of /WHOIS list.\r\n"}
        ])
      end)
    end

    test "handles WHOIS command with user nick target, invisible target user and user shares channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick", modes: [:i])
        channel = insert(:channel)
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_user_whois_message(user, target_user, channel)
      end)
    end

    test "handles WHOIS command with user nick target, invisible target user and user does not share secret channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick", modes: [:i])
        channel = insert(:channel, modes: [:s])
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_user_whois_message(user, target_user, nil)
      end)
    end

    test "handles WHOIS command with user nick target, invisible target user and user shares secret channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick", modes: [:i])
        channel = insert(:channel, modes: [:s])
        insert(:user_channel, user: user, channel: channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_user_whois_message(user, target_user, channel)
      end)
    end

    test "handles WHOIS command with user nick target and target user is an irc operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick", modes: [:o])
        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_user_whois_message(user, target_user, channel)
      end)
    end

    test "handles WHOIS command with registered user (+r mode)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick", modes: [:r])
        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 311 #{user.nick} #{target_user.nick} #{user.ident} hostname * :realname\r\n"},
          {user.pid, ":irc.test 307 #{user.nick} #{target_user.nick} :has identified for this nick\r\n"},
          {user.pid, ":irc.test 319 #{user.nick} #{target_user.nick} :#{channel.name}\r\n"},
          {user.pid, ":irc.test 312 #{user.nick} #{target_user.nick} irc.test :Elixir IRC daemon\r\n"},
          {user.pid, ~r/^:irc\.test 317 #{user.nick} #{target_user.nick} \d+ \d+ :seconds idle, signon time\r\n$/},
          {user.pid, ":irc.test 318 #{user.nick} #{target_user.nick} :End of /WHOIS list.\r\n"}
        ])
      end)
    end

    test "handles WHOIS command with user not registered (no +r mode)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick", modes: [])
        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        # Should not include the 307 registered response
        assert_sent_messages([
          {user.pid, ":irc.test 311 #{user.nick} #{target_user.nick} #{user.ident} hostname * :realname\r\n"},
          {user.pid, ":irc.test 319 #{user.nick} #{target_user.nick} :#{channel.name}\r\n"},
          {user.pid, ":irc.test 312 #{user.nick} #{target_user.nick} irc.test :Elixir IRC daemon\r\n"},
          {user.pid, ~r/^:irc\.test 317 #{user.nick} #{target_user.nick} \d+ \d+ :seconds idle, signon time\r\n$/},
          {user.pid, ":irc.test 318 #{user.nick} #{target_user.nick} :End of /WHOIS list.\r\n"}
        ])
      end)
    end

    test "handles WHOIS command with user nick target and target user is away" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick", away_message: "I'm away")
        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_user_whois_message(user, target_user, channel)
      end)
    end

    test "handles WHOIS command with user nick target and target user is identified" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick", identified_as: "account_name")
        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_user_whois_message(user, target_user, channel)
      end)
    end

    test "handles WHOIS command with user nick target and target user is a bot" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick", modes: [:B])
        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_user_whois_message(user, target_user, channel)
      end)
    end

    test "handles WHOIS command with target user having no channels" do
      Memento.transaction!(fn ->
        user = insert(:user)
        target_user = insert(:user, nick: "target_nick", modes: [])

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        # Should show the user but with no 319 channel list
        assert_sent_messages([
          {user.pid, ":irc.test 311 #{user.nick} #{target_user.nick} #{user.ident} hostname * :realname\r\n"},
          {user.pid, ":irc.test 312 #{user.nick} #{target_user.nick} irc.test :Elixir IRC daemon\r\n"},
          {user.pid, ~r/^:irc\.test 317 #{user.nick} #{target_user.nick} \d+ \d+ :seconds idle, signon time\r\n$/},
          {user.pid, ":irc.test 318 #{user.nick} #{target_user.nick} :End of /WHOIS list.\r\n"}
        ])
      end)
    end

    test "handles WHOIS command with modern IRC numeric order (registered, identified, bot, operator, away)" do
      Memento.transaction!(fn ->
        user = insert(:user)

        target_user =
          insert(:user,
            nick: "target_nick",
            modes: [:r, :B, :o],
            identified_as: "TestAccount",
            away_message: "Busy coding"
          )

        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 311 #{user.nick} #{target_user.nick} #{user.ident} hostname * :realname\r\n"},
          {user.pid, ":irc.test 307 #{user.nick} #{target_user.nick} :has identified for this nick\r\n"},
          {user.pid, ":irc.test 330 #{user.nick} #{target_user.nick} TestAccount :is logged in as TestAccount\r\n"},
          {user.pid, ":irc.test 335 #{user.nick} #{target_user.nick} :Is a bot on this server\r\n"},
          {user.pid, ":irc.test 319 #{user.nick} #{target_user.nick} :#{channel.name}\r\n"},
          {user.pid, ":irc.test 312 #{user.nick} #{target_user.nick} irc.test :Elixir IRC daemon\r\n"},
          {user.pid, ":irc.test 301 #{user.nick} #{target_user.nick} :Busy coding\r\n"},
          {user.pid, ":irc.test 313 #{user.nick} #{target_user.nick} :is an IRC operator\r\n"},
          {user.pid, ~r/^:irc\.test 317 #{user.nick} #{target_user.nick} \d+ \d+ :seconds idle, signon time\r\n$/},
          {user.pid, ":irc.test 318 #{user.nick} #{target_user.nick} :End of /WHOIS list.\r\n"}
        ])
      end)
    end

    test "shows real hostname to operator when target has +x mode" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: [:o])
        target_user = insert(:user, nick: "target_nick", modes: [:x], ip_address: {192, 168, 1, 100})
        channel = insert(:channel)
        insert(:user_channel, user: target_user, channel: channel)

        message = %Message{command: "WHOIS", params: ["target_nick"]}
        assert :ok = Whois.handle(operator, message)

        assert_sent_messages([
          {operator.pid, ~r/:irc\.test 311 #{operator.nick} #{target_user.nick} #{target_user.ident} .+ \* :realname/},
          {operator.pid,
           ~r/:irc\.test 338 #{operator.nick} #{target_user.nick} (hostname|192\.168\.1\.100) :is actually using host/},
          {operator.pid, ":irc.test 379 #{operator.nick} #{target_user.nick} :is using modes +x\r\n"},
          {operator.pid, ~r/:irc\.test 319 #{operator.nick} #{target_user.nick} :#{channel.name}/},
          {operator.pid, ~r/:irc\.test 312 #{operator.nick} #{target_user.nick} irc.test :Elixir IRC daemon/},
          {operator.pid, ~r/:irc\.test 317 #{operator.nick} #{target_user.nick} \d+ \d+ :seconds idle, signon time/},
          {operator.pid, ":irc.test 318 #{operator.nick} #{target_user.nick} :End of /WHOIS list.\r\n"}
        ])
      end)
    end
  end

  @spec assert_user_whois_message(User.t(), User.t(), Channel.t() | nil) :: :ok
  defp assert_user_whois_message(user, target_user, channel) do
    assert_sent_messages(
      [
        {user.pid, ":irc.test 311 #{user.nick} #{target_user.nick} #{user.ident} hostname * :realname\r\n"},
        target_user.modes |> Enum.find(fn mode -> mode == :r end) &&
          {user.pid, ":irc.test 307 #{user.nick} #{target_user.nick} :has identified for this nick\r\n"},
        target_user.identified_as &&
          {user.pid,
           ":irc.test 330 #{user.nick} #{target_user.nick} #{target_user.identified_as} :is logged in as #{target_user.identified_as}\r\n"},
        target_user.modes |> Enum.find(fn mode -> mode == :B end) &&
          {user.pid, ":irc.test 335 #{user.nick} #{target_user.nick} :Is a bot on this server\r\n"},
        channel && {user.pid, ":irc.test 319 #{user.nick} #{target_user.nick} :#{channel.name}\r\n"},
        {user.pid, ":irc.test 312 #{user.nick} #{target_user.nick} irc.test :Elixir IRC daemon\r\n"},
        target_user.away_message &&
          {user.pid, ":irc.test 301 #{user.nick} #{target_user.nick} :#{target_user.away_message}\r\n"},
        (:o in target_user.modes and (:H not in target_user.modes or :o in user.modes)) &&
          {user.pid, ":irc.test 313 #{user.nick} #{target_user.nick} :is an IRC operator\r\n"},
        {user.pid, ~r/^:irc\.test 317 #{user.nick} #{target_user.nick} \d+ \d+ :seconds idle, signon time\r\n$/},
        {user.pid, ":irc.test 318 #{user.nick} #{target_user.nick} :End of /WHOIS list.\r\n"}
      ]
      |> Enum.reject(&(&1 in [nil, false]))
    )
  end

  @spec assert_no_user_whois_message(User.t(), String.t()) :: :ok
  defp assert_no_user_whois_message(user, target_nick) do
    assert_sent_messages([
      {user.pid, ":irc.test 401 #{user.nick} #{target_nick} :No such nick\r\n"},
      {user.pid, ":irc.test 318 #{user.nick} #{target_nick} :End of /WHOIS list.\r\n"}
    ])
  end

  test "WHOIS resolves a server or local nick target and preserves channel status" do
    Memento.transaction!(fn ->
      user = insert(:user)
      target = insert(:user)

      for {name, modes} <- [{"#oper", [:o, :v]}, {"#voice", [:v]}] do
        channel = insert(:channel, name: name)
        insert(:user_channel, user: target, channel: channel, modes: modes)
      end

      for server <- ["IRC.TEST", target.nick] do
        assert :ok = Whois.handle(user, %Message{command: "WHOIS", params: [server, target.nick]})
      end

      assert_sent_messages_count_containing(user.pid, ~r/ 311 /, 2)
      assert_sent_messages_count_containing(user.pid, ~r/ 319 .*@#oper/, 2)
      assert_sent_messages_count_containing(user.pid, ~r/ 319 .*\+#voice/, 2)
      assert :ok = Whois.handle(user, %Message{command: "WHOIS", params: ["missing.server", target.nick]})
      assert_sent_messages_count_containing(user.pid, ~r/ 402 .*missing.server/, 1)
    end)
  end
end
