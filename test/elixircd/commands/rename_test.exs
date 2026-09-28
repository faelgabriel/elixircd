defmodule ElixIRCd.Commands.RenameTest do
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Command
  alias ElixIRCd.History
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelExcepts
  alias ElixIRCd.Repositories.ChannelInvexes
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.ChatHistory
  alias ElixIRCd.Repositories.Metadata
  alias ElixIRCd.Repositories.ReadMarkers
  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserChannels

  test "renames atomically, preserves membership modes and falls back to PART/JOIN" do
    Memento.transaction!(fn ->
      channel = insert(:channel, name: "#old", modes: [:m, {:k, "secret"}], topic: nil)
      operator = insert(:user, nick: "Operator", capabilities: ["draft/channel-rename"])
      legacy = insert(:user, nick: "Legacy")
      insert(:user_channel, user: operator, channel: channel, modes: [:o])
      insert(:user_channel, user: legacy, channel: channel, modes: [:v])

      request = %Message{command: "RENAME", params: ["#old", "#new"], trailing: "better name"}
      assert :ok = Command.dispatch(operator, request)

      assert_sent_messages([
        {operator.pid, ":Operator!~username@hostname RENAME #old #new :better name\r\n"},
        {legacy.pid, ":Legacy!~username@hostname PART #old :better name\r\n"},
        {legacy.pid, ":Legacy!~username@hostname JOIN #new\r\n"},
        {legacy.pid, ":irc.test 353 Legacy = #new :+Legacy @Operator\r\n"},
        {legacy.pid, ":irc.test 366 Legacy #new :End of NAMES list.\r\n"}
      ])

      assert {:error, :channel_not_found} = Channels.get_by_name("#old")
      assert {:ok, renamed} = Channels.get_by_name("#new")
      assert renamed.modes == [:m, {:k, "secret"}]
      assert {:ok, op_membership} = UserChannels.get_by_user_pid_and_channel_name(operator.pid, "#new")
      assert op_membership.modes == [:o]
      assert {:ok, legacy_membership} = UserChannels.get_by_user_pid_and_channel_name(legacy.pid, "#new")
      assert legacy_membership.modes == [:v]
      assert ChatHistory.for_target("channel:#old") == []
      assert Enum.map(ChatHistory.for_target("channel:#new"), & &1.message.command) == ["RENAME"]
    end)
  end

  test "fallback replays topic and NAMES after JOIN" do
    Memento.transaction!(fn ->
      channel = insert(:channel, name: "#old")
      operator = insert(:user, nick: "Operator", capabilities: ["draft/channel-rename"])
      legacy = insert(:user, nick: "Legacy")
      insert(:user_channel, user: operator, channel: channel, modes: [:o])
      insert(:user_channel, user: legacy, channel: channel)

      assert :ok = Command.dispatch(operator, %Message{command: "RENAME", params: ["#old", "#new"]})
      assert_sent_message_contains(legacy.pid, ~r/ PART #old /)
      assert_sent_message_contains(legacy.pid, ~r/ JOIN #new\r\n/)
      assert_sent_message_contains(legacy.pid, ~r/ 332 Legacy #new :topic/)
      assert_sent_message_contains(legacy.pid, ~r/ 333 Legacy #new setter /)
      assert_sent_message_contains(legacy.pid, ~r/ 353 Legacy = #new /)
      assert_sent_message_contains(legacy.pid, ~r/ 366 Legacy #new /)
    end)
  end

  test "case-only rename works without a legacy PART/JOIN and always includes a trailing reason" do
    Memento.transaction!(fn ->
      channel = insert(:channel, name: "#Mixed", topic: nil)
      operator = insert(:user, nick: "Operator", capabilities: ["draft/channel-rename"])
      legacy = insert(:user, nick: "Legacy")
      insert(:user_channel, user: operator, channel: channel, modes: [:o])
      insert(:user_channel, user: legacy, channel: channel)

      assert :ok = Command.dispatch(operator, %Message{command: "RENAME", params: ["#Mixed", "#MIXED"]})
      assert {:ok, renamed} = Channels.get_by_name("#mixed")
      assert renamed.name == "#MIXED"
      assert_sent_messages_amount(legacy.pid, 0)
      assert_sent_messages([{operator.pid, ":Operator!~username@hostname RENAME #Mixed #MIXED :\r\n"}])
    end)
  end

  test "accepts an unprefixed third reason and rejects extra parameters" do
    Memento.transaction!(fn ->
      channel = insert(:channel, name: "#old")
      user = insert(:user, nick: "Operator", capabilities: ["draft/channel-rename"])
      insert(:user_channel, user: user, channel: channel, modes: [:o])

      assert :ok = Command.dispatch(user, %Message{command: "RENAME", params: ["#old", "#new", "why", "extra"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL RENAME INVALID_PARAMS #old #new /)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = Command.dispatch(user, %Message{command: "RENAME", params: ["#old", "#new", "why"]})
      assert_sent_message_contains(user.pid, ~r/ RENAME #old #new :why/)
    end)
  end

  test "requires channel operator privileges and a free destination" do
    Memento.transaction!(fn ->
      old = insert(:channel, name: "#old")
      insert(:channel, name: "#taken")
      user = insert(:user, nick: "User", capabilities: ["draft/channel-rename"])
      insert(:user_channel, user: user, channel: old)

      assert :ok = Command.dispatch(user, %Message{command: "RENAME", params: ["#old", "#new"]})
      assert_sent_message_contains(user.pid, ~r/ 482 User #old :You're not channel operator/)
      Agent.update(@agent_name, fn _ -> [] end)

      membership = UserChannels.get_by_user_pid_and_channel_name(user.pid, "#old") |> elem(1)
      UserChannels.update(membership, %{modes: [:o]})
      assert :ok = Command.dispatch(user, %Message{command: "RENAME", params: ["#old", "#taken"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL RENAME CHANNEL_NAME_IN_USE #old #taken /)
    end)
  end

  test "migrates history and read markers without rewriting unrelated event parameters" do
    Memento.transaction!(fn ->
      channel = insert(:channel, name: "#old")

      operator =
        insert(:user,
          nick: "Operator",
          identified_as: "Operator",
          capabilities: ["draft/channel-rename"]
        )

      insert(:user_channel, user: operator, channel: channel, modes: [:o])
      timestamp = DateTime.utc_now() |> DateTime.truncate(:millisecond)

      History.record(
        %Message{
          prefix: "Operator!~username@hostname",
          command: "PRIVMSG",
          params: ["#old"],
          trailing: "before rename",
          tags: %{"msgid" => "before-rename", "time" => DateTime.to_iso8601(timestamp)}
        },
        operator
      )

      History.record_channel_event(%Message{command: "NICK", params: ["UnrelatedNick"]}, operator, "#old")
      ReadMarkers.put("account:operator", "#old", "#old", timestamp)

      assert :ok =
               Command.dispatch(operator, %Message{
                 command: "RENAME",
                 params: ["#old", "#new"],
                 trailing: "better name"
               })

      assert ChatHistory.for_target("channel:#old") == []
      entries = ChatHistory.for_target("channel:#new")
      assert length(entries) == 3

      message = Enum.find(entries, &(&1.msgid == "before-rename"))
      assert message.target_name == "#new"
      assert message.message.params == ["#new"]

      nick_event = Enum.find(entries, &match?(%Message{command: "NICK"}, &1.message))
      assert nick_event.message.params == ["UnrelatedNick"]

      rename_event = Enum.find(entries, &match?(%Message{command: "RENAME"}, &1.message))
      assert rename_event.message.params == ["#old", "#new"]

      assert {:error, :read_marker_not_found} = ReadMarkers.get("account:operator", "#old")
      assert {:ok, marker} = ReadMarkers.get("account:operator", "#new")
      assert marker.target == "#new"
      assert marker.timestamp == timestamp
    end)
  end

  test "moves channel bans, exceptions and invites with their channel" do
    Memento.transaction!(fn ->
      channel = insert(:channel, name: "#old")
      operator = insert(:user, nick: "Operator", capabilities: ["draft/channel-rename"])
      invitee = insert(:user)
      insert(:user_channel, user: operator, channel: channel, modes: [:o])
      insert(:channel_ban, channel: channel)
      insert(:channel_except, channel: channel)
      insert(:channel_invex, channel: channel)
      insert(:channel_invite, channel: channel, user: invitee)

      assert :ok = Command.dispatch(operator, %Message{command: "RENAME", params: ["#old", "#new"]})

      for repository <- [ChannelBans, ChannelExcepts, ChannelInvexes, ChannelInvites] do
        assert repository.get_by_channel_name_key("#old") == []
        assert [record] = repository.get_by_channel_name_key("#new")
        assert record.channel_name_key == "#new"
      end

      assert [invite] = ChannelInvites.get_by_channel_name_key("#new")
      assert invite.user_pid == invitee.pid
    end)
  end

  test "reports availability, naming, membership, reason and parameter errors" do
    original = Application.fetch_env!(:elixircd, :channel_rename)
    on_exit(fn -> Application.put_env(:elixircd, :channel_rename, original) end)
    Application.put_env(:elixircd, :channel_rename, Keyword.put(original, :max_reason_length, 3))

    Memento.transaction!(fn ->
      unavailable = insert(:user, nick: "Unavailable")
      Application.put_env(:elixircd, :channel_rename, Keyword.put(original, :enabled, false))
      assert :ok = Command.dispatch(unavailable, %Message{command: "RENAME", params: ["#old", "#new"]})
      assert_sent_message_contains(unavailable.pid, ~r/ FAIL RENAME CANNOT_RENAME #old #new /)

      Application.put_env(
        :elixircd,
        :channel_rename,
        original |> Keyword.put(:enabled, true) |> Keyword.put(:max_reason_length, 3)
      )

      user = insert(:user, nick: "Operator", capabilities: ["draft/channel-rename"])
      assert :ok = Command.dispatch(user, %Message{command: "RENAME", params: []})
      assert_sent_message_contains(user.pid, ~r/ 461 Operator RENAME :Not enough parameters/)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = Command.dispatch(user, %Message{command: "RENAME", params: ["#missing", "#new"]})
      assert_sent_message_contains(user.pid, ~r/ 403 Operator #missing :No such channel/)
      Agent.update(@agent_name, fn _ -> [] end)

      channel = insert(:channel, name: "#old")
      assert :ok = Command.dispatch(user, %Message{command: "RENAME", params: ["#old", "invalid"]})
      assert_sent_message_contains(user.pid, ~r/ FAIL RENAME CANNOT_RENAME #old invalid /)
      Agent.update(@agent_name, fn _ -> [] end)

      assert :ok = Command.dispatch(user, %Message{command: "RENAME", params: ["#old", "#new"]})
      assert_sent_message_contains(user.pid, ~r/ 442 Operator #old :You're not on that channel/)
      Agent.update(@agent_name, fn _ -> [] end)

      insert(:user_channel, user: user, channel: channel, modes: [:o])

      assert :ok =
               Command.dispatch(user, %Message{
                 command: "RENAME",
                 params: ["#old", "#new"],
                 trailing: "long"
               })

      assert_sent_message_contains(user.pid, ~r/ FAIL RENAME CANNOT_RENAME #old #new /)
    end)
  end

  test "migrates registered-channel, access, metadata and multiline history records" do
    Memento.transaction!(fn ->
      channel = insert(:channel, name: "#old")
      user = insert(:user, nick: "Operator", capabilities: ["draft/channel-rename"])
      insert(:user_channel, user: user, channel: channel, modes: [:o])
      insert(:registered_channel, name: "#old")
      insert(:registered_channel_access, channel_name: "#old", account_name: "Alice")
      Metadata.put(:channel, channel.name_key, "color", "blue")

      timestamp = DateTime.utc_now() |> DateTime.truncate(:millisecond)

      multiline = %{
        kind: :multiline,
        target: "#old",
        tags: %{},
        lines: [%Message{command: "PRIVMSG", params: ["#old"], trailing: "line"}]
      }

      ChatHistory.create(%{
        id: {"channel:#old", DateTime.to_unix(timestamp, :microsecond), "multi"},
        target_type: :channel,
        target_key: "channel:#old",
        target_name: "#old",
        msgid: "multi",
        sender_account_key: nil,
        recipient_account_key: nil,
        message: multiline,
        occurred_at: timestamp
      })

      ChatHistory.create(%{
        id: {"channel:#old", DateTime.to_unix(timestamp, :microsecond) + 1, "other"},
        target_type: :channel,
        target_key: "channel:#old",
        target_name: "#old",
        msgid: "other",
        sender_account_key: nil,
        recipient_account_key: nil,
        message: %{kind: :multiline, target: "#other", tags: %{}, lines: []},
        occurred_at: DateTime.add(timestamp, 1, :microsecond)
      })

      ChatHistory.create(%{
        id: {"channel:#old", DateTime.to_unix(timestamp, :microsecond) + 2, "opaque"},
        target_type: :channel,
        target_key: "channel:#old",
        target_name: "#old",
        msgid: "opaque",
        sender_account_key: nil,
        recipient_account_key: nil,
        message: %{kind: :opaque},
        occurred_at: DateTime.add(timestamp, 2, :microsecond)
      })

      assert :ok = Command.dispatch(user, %Message{command: "RENAME", params: ["#old", "#new"]})
      assert {:ok, registered} = RegisteredChannels.get_by_name("#new")
      assert registered.name == "#new"
      assert [_] = RegisteredChannelAccesses.get_by_channel_name("#new")
      assert Metadata.get(:channel, "#new", "color").value == "blue"

      entries = ChatHistory.for_target("channel:#new")
      rewritten = Enum.find(entries, &(&1.msgid == "multi")).message
      assert rewritten.target == "#new"
      assert hd(rewritten.lines).params == ["#new"]
      assert Enum.find(entries, &(&1.msgid == "other")).message.target == "#other"
      assert Enum.find(entries, &(&1.msgid == "opaque")).message == %{kind: :opaque}
    end)
  end
end
