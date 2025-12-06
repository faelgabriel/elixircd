defmodule ElixIRCd.Commands.ModeTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Commands.Mode
  alias ElixIRCd.Message

  describe "handle/2 for channel" do
    test "handles MODE command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "MODE", params: ["#anything"]}

        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles MODE command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "MODE", params: []}

        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} MODE :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles MODE command for non-existing channel" do
      Memento.transaction!(fn ->
        user = insert(:user)

        message = %Message{command: "MODE", params: ["#channel"]}
        assert :ok = Mode.handle(user, message)

        message = %Message{command: "MODE", params: ["#channel", "+t"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 403 #{user.nick} #channel :No such channel\r\n"},
          {user.pid, ":irc.test 403 #{user.nick} #channel :No such channel\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and user is not in the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel)

        message = %Message{command: "MODE", params: [channel.name]}
        assert :ok = Mode.handle(user, message)

        message = %Message{command: "MODE", params: [channel.name, "+t"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 442 #{user.nick} #{channel.name} :You're not on that channel\r\n"},
          {user.pid, ":irc.test 442 #{user.nick} #{channel.name} :You're not on that channel\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and without mode parameter" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["t", "n", {"l", "10"}])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} MODE #{channel.name} +tnl 10\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and add modes" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["n", {"l", "10"}])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "+t+s"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} MODE #{channel.name} +ts\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and remove modes" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["n", "t", "s", {"l", "10"}])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "-t-s"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} MODE #{channel.name} -ts\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and add modes with value" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["n", {"l", "10"}])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "+t+l+k", "20", "password"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} MODE #{channel.name} +tlk 20 password\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and remove modes with value" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["t", {"l", "20"}, {"k", "password"}])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "-l-k"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} MODE #{channel.name} -lk\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and remove modes with value that do not need value to be removed" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["t", {"l", "20"}, {"k", "password"}])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "-t-l-k"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} MODE #{channel.name} -tlk\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and add modes for user channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        user_operator = insert(:user, nick: "nick_operator")
        user_voice = insert(:user, nick: "nick_voice")
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:user_channel, user: user_operator, channel: channel, modes: [])
        insert(:user_channel, user: user_voice, channel: channel, modes: [])

        message = %Message{command: "MODE", params: [channel.name, "+ov", user_operator.nick, user_voice.nick]}
        assert :ok = Mode.handle(user, message)

        mode_change_message =
          ":#{user_mask(user)} MODE #{channel.name} +ov #{user_operator.nick} #{user_voice.nick}\r\n"

        assert_sent_messages([
          {user.pid, mode_change_message},
          {user_operator.pid, mode_change_message},
          {user_voice.pid, mode_change_message}
        ])
      end)
    end

    test "handles MODE command for channel and remove modes for user channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        user_operator = insert(:user, nick: "nick_operator")
        user_voice = insert(:user, nick: "nick_voice")
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:user_channel, user: user_operator, channel: channel, modes: ["o"])
        insert(:user_channel, user: user_voice, channel: channel, modes: ["v"])

        message = %Message{command: "MODE", params: [channel.name, "-ov", user_operator.nick, user_voice.nick]}
        assert :ok = Mode.handle(user, message)

        mode_change_message =
          ":#{user_mask(user)} MODE #{channel.name} -ov #{user_operator.nick} #{user_voice.nick}\r\n"

        assert_sent_messages([
          {user.pid, mode_change_message},
          {user_operator.pid, mode_change_message},
          {user_voice.pid, mode_change_message}
        ])
      end)
    end

    test "handles MODE command for channel and add modes for user that is not in the channel" do
      Memento.transaction!(fn ->
        user = insert(:user)
        user_operator = insert(:user, nick: "nick_operator")
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "+o", user_operator.nick]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 441 #{user.nick} #{channel.name} #{user_operator.nick} :They aren't on that channel\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and add modes for user that is not in the server" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "+o", "nonexistent"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 401 #{user.nick} #{channel.name} nonexistent :No such nick\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and add modes for channel ban" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "+b", "nick!user@host"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} MODE #{channel.name} +b nick!user@host\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and remove modes for channel ban" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:channel_ban, channel: channel, mask: "nick!user@host")

        message = %Message{command: "MODE", params: [channel.name, "-b", "nick!user@host"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} MODE #{channel.name} -b nick!user@host\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel to remove modes for channel ban that does not exist" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "-b", "inexistent!@mask"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles MODE command for channel to list bans" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        channel_ban = insert(:channel_ban, channel: channel, mask: "nick!user@host")

        message = %Message{command: "MODE", params: [channel.name, "+b"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 367 #{user.nick} #{channel.name} #{channel_ban.mask} #{channel_ban.setter} #{DateTime.to_unix(channel_ban.created_at)}\r\n"},
          {user.pid, ":irc.test 368 #{user.nick} #{channel.name} :End of channel ban list\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel to list bans when over the max_list_entries limit" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        # Create 150 bans (over the default limit of 100)
        ban_masks = for i <- 1..150, do: "user#{i}!*@*"
        _channel_bans = for mask <- ban_masks, do: insert(:channel_ban, channel: channel, mask: mask)

        message = %Message{command: "MODE", params: [channel.name, "+b"]}
        assert :ok = Mode.handle(user, message)

        # Verify we have exactly 100 ban messages (367 replies)
        assert_sent_messages_count_containing(user.pid, ~r/367/, 100)

        # Verify the truncation notice is present
        assert_sent_message_contains(
          user.pid,
          ~r/Ban list for #{Regex.escape(channel.name)} too long, showing first 100 of 150 entries/
        )

        # Verify the end message is present
        assert_sent_message_contains(user.pid, ~r/368.*End of channel ban list/)

        # Verify we have exactly 102 messages total (100 bans + 1 truncation notice + 1 end)
        assert_sent_messages_amount(user.pid, 102)
      end)
    end

    test "handles MODE command for channel and add modes for channel except (+e)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "+e", "nick!user@host"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} MODE #{channel.name} +e nick!user@host\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and remove modes for channel except (+e)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:channel_except, channel: channel, mask: "nick!user@host")

        message = %Message{command: "MODE", params: [channel.name, "-e", "nick!user@host"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} MODE #{channel.name} -e nick!user@host\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel to remove modes for channel except that does not exist" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "-e", "inexistent!@mask"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles MODE command for channel to add channel except that already exists" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:channel_except, channel: channel, mask: "nick!user@host")

        message = %Message{command: "MODE", params: [channel.name, "+e", "nick!user@host"]}
        assert :ok = Mode.handle(user, message)

        # Should not send any mode change message since except already exists
        assert_sent_messages([])
      end)
    end

    test "handles MODE command for channel to list except (+e)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        channel_except = insert(:channel_except, channel: channel, mask: "nick!user@host")

        message = %Message{command: "MODE", params: [channel.name, "+e"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 348 #{user.nick} #{channel.name} #{channel_except.mask} #{channel_except.setter} #{DateTime.to_unix(channel_except.created_at)}\r\n"},
          {user.pid, ":irc.test 349 #{user.nick} #{channel.name} :End of channel except list\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel to list except when over the max_list_entries limit" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        # Create 150 excepts (over the default limit of 100)
        except_masks = for i <- 1..150, do: "user#{i}!*@*"
        _channel_excepts = for mask <- except_masks, do: insert(:channel_except, channel: channel, mask: mask)

        message = %Message{command: "MODE", params: [channel.name, "+e"]}
        assert :ok = Mode.handle(user, message)

        # Verify we have exactly 100 except messages (348 replies)
        assert_sent_messages_count_containing(user.pid, ~r/348/, 100)

        # Verify the truncation notice is present
        assert_sent_message_contains(
          user.pid,
          ~r/Except list for #{Regex.escape(channel.name)} too long, showing first 100 of 150 entries/
        )

        # Verify the end message is present
        assert_sent_message_contains(user.pid, ~r/349.*End of channel except list/)

        # Verify we have exactly 102 messages total (100 excepts + 1 truncation notice + 1 end)
        assert_sent_messages_amount(user.pid, 102)
      end)
    end

    test "handles MODE command for channel and add modes for channel invex (+I)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "+I", "nick!user@host"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} MODE #{channel.name} +I nick!user@host\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel and remove modes for channel invex (+I)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:channel_invex, channel: channel, mask: "nick!user@host")

        message = %Message{command: "MODE", params: [channel.name, "-I", "nick!user@host"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} MODE #{channel.name} -I nick!user@host\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel to remove modes for channel invex that does not exist" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "-I", "inexistent!@mask"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles MODE command for channel to add channel invex that already exists" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        insert(:channel_invex, channel: channel, mask: "nick!user@host")

        message = %Message{command: "MODE", params: [channel.name, "+I", "nick!user@host"]}
        assert :ok = Mode.handle(user, message)

        # Should not send any mode change message since invex already exists
        assert_sent_messages([])
      end)
    end

    test "handles MODE command for channel to list invex (+I)" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])
        channel_invex = insert(:channel_invex, channel: channel, mask: "nick!user@host")

        message = %Message{command: "MODE", params: [channel.name, "+I"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 346 #{user.nick} #{channel.name} #{channel_invex.mask} #{channel_invex.setter} #{DateTime.to_unix(channel_invex.created_at)}\r\n"},
          {user.pid, ":irc.test 347 #{user.nick} #{channel.name} :End of channel invex list\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel to list invex when over the max_list_entries limit" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        # Create 150 invexes (over the default limit of 100)
        invex_masks = for i <- 1..150, do: "user#{i}!*@*"
        _channel_invexes = for mask <- invex_masks, do: insert(:channel_invex, channel: channel, mask: mask)

        message = %Message{command: "MODE", params: [channel.name, "+I"]}
        assert :ok = Mode.handle(user, message)

        # Verify we have exactly 100 invex messages (346 replies)
        assert_sent_messages_count_containing(user.pid, ~r/346/, 100)

        # Verify the truncation notice is present
        assert_sent_message_contains(
          user.pid,
          ~r/Invex list for #{Regex.escape(channel.name)} too long, showing first 100 of 150 entries/
        )

        # Verify the end message is present
        assert_sent_message_contains(user.pid, ~r/347.*End of channel invex list/)

        # Verify we have exactly 102 messages total (100 invexes + 1 truncation notice + 1 end)
        assert_sent_messages_amount(user.pid, 102)
      end)
    end

    test "handles MODE command for channel when invalid modes sent" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "+wa"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 472 #{user.nick} w :is unknown mode char to me\r\n"},
          {user.pid, ":irc.test 472 #{user.nick} a :is unknown mode char to me\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel when no modes changed" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: ["t"])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "+t"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "handles MODE command for channel when mode changes are missing values" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        message = %Message{command: "MODE", params: [channel.name, "+l"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} MODE :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel when user is not an operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel)

        message = %Message{command: "MODE", params: [channel.name, "+t"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 482 #{user.nick} #{channel.name} :You're not a channel operator\r\n"}
        ])
      end)
    end

    test "handles MODE command for channel when mode changes exceed the limit" do
      original_config = Application.get_env(:elixircd, :channel)
      Application.put_env(:elixircd, :channel, original_config |> Keyword.put(:max_modes_per_command, 4))
      on_exit(fn -> Application.put_env(:elixircd, :channel, original_config) end)

      Memento.transaction!(fn ->
        user = insert(:user)
        channel = insert(:channel, modes: [])
        insert(:user_channel, user: user, channel: channel, modes: ["o"])

        # Test with 5 modes (over limit of 4)
        message = %Message{command: "MODE", params: [channel.name, "+tnmis"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 472 #{user.nick} #{channel.name} :Too many channel modes in one command (maximum is 4)\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 for user" do
    test "handles MODE command for user that list its modes" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["i", "w", "o", "Z"])

        message = %Message{command: "MODE", params: [user.nick]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 221 #{user.nick} +iwoZ\r\n"}
        ])
      end)
    end

    test "handles MODE command for user that change its modes" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: [])

        message = %Message{command: "MODE", params: [user.nick, "+iw"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} MODE #{user.nick} +iw\r\n"}
        ])
      end)
    end

    test "handles MODE command for user that change its modes with invalid modes" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: [])

        message = %Message{command: "MODE", params: [user.nick, "+iywz"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} MODE #{user.nick} +iw\r\n"},
          {user.pid, ":irc.test 472 #{user.nick} y :is unknown mode char to me\r\n"},
          {user.pid, ":irc.test 472 #{user.nick} z :is unknown mode char to me\r\n"}
        ])
      end)
    end

    test "handles MODE command for non-operator listing another user modes" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user, modes: ["i", "w", "o", "Z"])

        message = %Message{command: "MODE", params: [another_user.nick]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 502 #{user.nick} :Cannot change mode for other users\r\n"}
        ])
      end)
    end

    test "handles MODE command for operator listing another user modes" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: ["o"])
        another_user = insert(:user, modes: ["i", "w", "B", "Z"])

        message = %Message{command: "MODE", params: [another_user.nick]}
        assert :ok = Mode.handle(operator, message)

        assert_sent_messages([
          {operator.pid, ":irc.test 221 #{operator.nick} +iwBZ\r\n"}
        ])
      end)
    end

    test "handles MODE command for operator listing non-existent user modes" do
      Memento.transaction!(fn ->
        operator = insert(:user, modes: ["o"])

        message = %Message{command: "MODE", params: ["nonexistent"]}
        assert :ok = Mode.handle(operator, message)

        assert_sent_messages([
          {operator.pid, ":irc.test 401 #{operator.nick} nonexistent :No such nick\r\n"}
        ])
      end)
    end

    test "handles MODE command for user that change another user modes" do
      Memento.transaction!(fn ->
        user = insert(:user)
        another_user = insert(:user)

        message = %Message{command: "MODE", params: [another_user.nick, "+i"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 502 #{user.nick} :Cannot change mode for other users\r\n"}
        ])
      end)
    end

    test "handles MODE command for user setting and removing +B on themselves" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: [])

        message = %Message{command: "MODE", params: [user.nick, "+B"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} MODE #{user.nick} +B\r\n"}
        ])

        user_with_mode = %{user | modes: ["B"]}
        message = %Message{command: "MODE", params: [user_with_mode.nick, "-B"]}
        assert :ok = Mode.handle(user_with_mode, message)

        assert_sent_messages([
          {user_with_mode.pid, ":#{user_mask(user_with_mode)} MODE #{user_with_mode.nick} -B\r\n"}
        ])
      end)
    end

    test "handles MODE command for user setting and removing +g on themselves" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: [])

        message = %Message{command: "MODE", params: [user.nick, "+g"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":#{user_mask(user)} MODE #{user.nick} +g\r\n"}
        ])

        user_with_mode = %{user | modes: ["g"]}
        message = %Message{command: "MODE", params: [user_with_mode.nick, "-g"]}
        assert :ok = Mode.handle(user_with_mode, message)

        assert_sent_messages([
          {user_with_mode.pid, ":#{user_mask(user_with_mode)} MODE #{user_with_mode.nick} -g\r\n"}
        ])
      end)
    end

    test "handles MODE command for non-operator attempting to set operator-restricted modes" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: [])

        message = %Message{command: "MODE", params: [user.nick, "+H"]}
        assert :ok = Mode.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 481 #{user.nick} :Permission Denied- You don't have privileges to change mode H\r\n"}
        ])
      end)
    end
  end
end
