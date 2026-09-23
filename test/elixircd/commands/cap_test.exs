defmodule ElixIRCd.Commands.CapTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Cap
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.SaslSessions
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Connection
  alias ElixIRCd.Server.ResponseContext

  describe "handle/2 - CAP LS" do
    test "handles CAP LS command for listing supported capabilities for IRCv3.1" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || [])
        |> Keyword.put(:account_tag, true)
        |> Keyword.put(:account_notify, true)
        |> Keyword.put(:away_notify, true)
        |> Keyword.put(:cap_notify, false)
        |> Keyword.put(:chghost, true)
        |> Keyword.put(:extended_join, true)
        |> Keyword.put(:invite_notify, true)
        |> Keyword.put(:multi_prefix, true)
        |> Keyword.put(:setname, true)
        |> Keyword.put(:extended_names, true)
        |> Keyword.put(:message_tags, true)
        |> Keyword.put(:server_time, true)
        |> Keyword.put(:sts, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test CAP * LS :account-tag account-notify draft/account-registration away-notify batch chghost draft/chathistory draft/channel-rename draft/event-playback echo-message extended-join extended-monitor invite-notify draft/message-redaction draft/metadata-2 draft/metadata-3 labeled-response multi-prefix draft/multiline draft/read-marker sasl setname standard-replies server-time message-tags userhost-in-names\r\n"}
        ])
      end)
    end

    test "CAP LS enables cap_negotiating flag on first call" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, cap_negotiating: nil)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        # Verify cap_negotiating was set to true
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert updated_user.cap_negotiating == true
      end)
    end

    test "CAP LS keeps cap_negotiating enabled if already active" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, cap_negotiating: true)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        # Verify cap_negotiating is still true
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert updated_user.cap_negotiating == true
      end)
    end

    test "handles CAP LS command for listing supported capabilities for IRCv3.2" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || [])
        |> Keyword.put(:account_tag, true)
        |> Keyword.put(:account_notify, true)
        |> Keyword.put(:away_notify, true)
        |> Keyword.put(:cap_notify, false)
        |> Keyword.put(:chghost, true)
        |> Keyword.put(:extended_join, true)
        |> Keyword.put(:invite_notify, true)
        |> Keyword.put(:multi_prefix, true)
        |> Keyword.put(:setname, true)
        |> Keyword.put(:extended_names, true)
        |> Keyword.put(:message_tags, true)
        |> Keyword.put(:server_time, true)
        |> Keyword.put(:sts, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, transport: :tls)
        message = %Message{command: "CAP", params: ["LS", "302"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test CAP * LS :account-tag account-notify draft/account-registration away-notify batch cap-notify chghost draft/chathistory draft/channel-rename draft/event-playback echo-message extended-join extended-monitor invite-notify draft/message-redaction draft/metadata-2=before-connect,max-subs=50,max-keys=20,max-value-bytes=400 draft/metadata-3=before-connect,max-subs=50,max-keys=20,max-value-bytes=400 labeled-response multi-prefix draft/multiline=max-bytes=4096,max-lines=32 draft/read-marker sasl=PLAIN,SCRAM-SHA-256 setname standard-replies server-time message-tags userhost-in-names\r\n"}
        ])
      end)
    end

    test "handles CAP LS when extended names are disabled" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || [])
        |> Keyword.put(:account_tag, true)
        |> Keyword.put(:account_notify, true)
        |> Keyword.put(:away_notify, true)
        |> Keyword.put(:cap_notify, false)
        |> Keyword.put(:chghost, true)
        |> Keyword.put(:extended_join, true)
        |> Keyword.put(:invite_notify, true)
        |> Keyword.put(:multi_prefix, true)
        |> Keyword.put(:setname, true)
        |> Keyword.put(:extended_names, false)
        |> Keyword.put(:sts, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test CAP #{user.nick} LS :account-tag account-notify draft/account-registration away-notify batch chghost draft/chathistory draft/channel-rename draft/event-playback echo-message extended-join extended-monitor invite-notify draft/message-redaction draft/metadata-2 draft/metadata-3 labeled-response multi-prefix draft/multiline draft/read-marker sasl setname standard-replies server-time message-tags\r\n"}
        ])
      end)
    end

    test "removed legacy configuration does not advertise custom capabilities" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        Keyword.merge(original_config, extended_uhlist: true, invite_extended: true)
      )

      Memento.transaction!(fn ->
        user = insert(:user)
        assert :ok = Cap.handle(user, %Message{command: "CAP", params: ["LS"]})
        assert_sent_messages_count_containing(user.pid, ~r/ (uhnames|extended-uhlist|invite-extended)(?: |\r)/, 0)
        assert_sent_message_contains(user.pid, ~r/ userhost-in-names(?: |\r)/)
      end)
    end

    test "handles CAP LS when all capabilities are disabled" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        original_config
        |> Keyword.put(:account_tag, false)
        |> Keyword.put(:account_notify, false)
        |> Keyword.put(:account_registration, false)
        |> Keyword.put(:away_notify, false)
        |> Keyword.put(:batch, false)
        |> Keyword.put(:cap_notify, false)
        |> Keyword.put(:chghost, false)
        |> Keyword.put(:chathistory, false)
        |> Keyword.put(:channel_rename, false)
        |> Keyword.put(:event_playback, false)
        |> Keyword.put(:echo_message, false)
        |> Keyword.put(:extended_join, false)
        |> Keyword.put(:extended_monitor, false)
        |> Keyword.put(:invite_notify, false)
        |> Keyword.put(:message_redaction, false)
        |> Keyword.put(:metadata, false)
        |> Keyword.put(:multi_prefix, false)
        |> Keyword.put(:multiline, false)
        |> Keyword.put(:read_marker, false)
        |> Keyword.put(:setname, false)
        |> Keyword.put(:standard_replies, false)
        |> Keyword.put(:extended_names, false)
        |> Keyword.put(:message_tags, false)
        |> Keyword.put(:server_time, false)
        |> Keyword.put(:labeled_response, false)
        |> Keyword.put(:sts, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} LS :sasl\r\n"}
        ])
      end)
    end

    test "handles CAP LS when SASL is disabled" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        original_config
        |> Keyword.put(:account_tag, true)
        |> Keyword.put(:account_notify, true)
        |> Keyword.put(:away_notify, true)
        |> Keyword.put(:cap_notify, false)
        |> Keyword.put(:chghost, true)
        |> Keyword.put(:extended_join, true)
        |> Keyword.put(:invite_notify, true)
        |> Keyword.put(:multi_prefix, true)
        |> Keyword.put(:setname, true)
        |> Keyword.put(:server_time, true)
        |> Keyword.put(:message_tags, true)
        |> Keyword.put(:extended_names, true)
        |> Keyword.put(:sasl, false)
        |> Keyword.put(:sts, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test CAP #{user.nick} LS :account-tag account-notify draft/account-registration away-notify batch chghost draft/chathistory draft/channel-rename draft/event-playback echo-message extended-join extended-monitor invite-notify draft/message-redaction draft/metadata-2 draft/metadata-3 labeled-response multi-prefix draft/multiline draft/read-marker setname standard-replies server-time message-tags userhost-in-names\r\n"}
        ])
      end)
    end

    test "handles CAP LS when SASL PLAIN mechanism is disabled" do
      original_caps = Application.get_env(:elixircd, :capabilities)
      original_sasl = Application.get_env(:elixircd, :sasl)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, original_caps)
        Application.put_env(:elixircd, :sasl, original_sasl)
      end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_caps || [])
        |> Keyword.put(:account_tag, true)
        |> Keyword.put(:account_notify, true)
        |> Keyword.put(:away_notify, true)
        |> Keyword.put(:cap_notify, false)
        |> Keyword.put(:chghost, true)
        |> Keyword.put(:extended_join, true)
        |> Keyword.put(:invite_notify, true)
        |> Keyword.put(:multi_prefix, true)
        |> Keyword.put(:setname, true)
        |> Keyword.put(:server_time, true)
        |> Keyword.put(:message_tags, true)
        |> Keyword.put(:extended_names, true)
        |> Keyword.put(:sasl, true)
        |> Keyword.put(:sts, false)
      )

      Application.put_env(
        :elixircd,
        :sasl,
        plain: [enabled: false]
      )

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        # SASL should not be in the list when no mechanisms are enabled
        assert_sent_messages([
          {user.pid,
           ":irc.test CAP #{user.nick} LS :account-tag account-notify draft/account-registration away-notify batch chghost draft/chathistory draft/channel-rename draft/event-playback echo-message extended-join extended-monitor invite-notify draft/message-redaction draft/metadata-2 draft/metadata-3 labeled-response multi-prefix draft/multiline draft/read-marker setname standard-replies server-time message-tags userhost-in-names\r\n"}
        ])
      end)
    end

    test "CAP version persists, enables notifications, and controls capability values" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, transport: :tls)

        for version <- ["invalid", "301", "307", "302"] do
          {:ok, user} = Users.get_by_pid(user.pid)
          Cap.handle(user, %Message{command: "CAP", params: ["LS", version]})
        end

        {:ok, user} = Users.get_by_pid(user.pid)
        assert user.cap_version == 307
        assert "cap-notify" in user.capabilities
        assert_sent_messages_count_containing(user.pid, ~r/sasl=PLAIN/, 2)
        assert_sent_messages_amount(user.pid, 4)

        Cap.handle(user, %Message{command: "CAP", params: ["LS"]})
        assert_sent_messages_count_containing(user.pid, ~r/sasl=/, 0)
        {:ok, user} = Users.get_by_pid(user.pid)
        assert user.cap_version == 307
        Cap.handle(user, %Message{command: "CAP", params: ["REQ", "-cap-notify"]})
        assert_sent_message_contains(user.pid, ":irc.test CAP * NAK :-cap-notify\r\n")
        {:ok, user} = Users.get_by_pid(user.pid)
        assert "cap-notify" in user.capabilities
      end)
    end
  end

  describe "handle/2 - CAP LIST" do
    test "handles CAP LIST command with no capabilities enabled" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["LIST"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} LIST :\r\n"}
        ])
      end)
    end

    test "handles CAP LIST command with userhost-in-names capability enabled" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["userhost-in-names"])
        message = %Message{command: "CAP", params: ["LIST"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} LIST :userhost-in-names\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - CAP REQ" do
    test "handles CAP REQ command to request userhost-in-names capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "userhost-in-names"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :userhost-in-names\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert "userhost-in-names" in updated_user.capabilities
      end)
    end

    test "handles CAP REQ command with trailing parameter" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ"], trailing: "userhost-in-names"}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :userhost-in-names\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert "userhost-in-names" in updated_user.capabilities
      end)
    end

    test "CAP REQ enables cap_negotiating flag for unregistered users" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, cap_negotiating: nil, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ"], trailing: "multi-prefix"}

        assert :ok = Cap.handle(user, message)

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert updated_user.cap_negotiating == true
      end)
    end

    test "CAP REQ does not touch cap_negotiating flag for registered users" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: true, cap_negotiating: false, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ"], trailing: "multi-prefix"}

        assert :ok = Cap.handle(user, message)

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert updated_user.cap_negotiating == false
        assert "multi-prefix" in updated_user.capabilities
      end)
    end

    test "handles CAP REQ command to disable userhost-in-names capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["userhost-in-names"])
        message = %Message{command: "CAP", params: ["REQ", "-userhost-in-names"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :-userhost-in-names\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert "userhost-in-names" not in updated_user.capabilities
      end)
    end

    test "handles CAP REQ command to request extended-join capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "extended-join"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :extended-join\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert "extended-join" in updated_user.capabilities
      end)
    end

    test "handles CAP REQ command to disable extended-join capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["extended-join"])
        message = %Message{command: "CAP", params: ["REQ", "-extended-join"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :-extended-join\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert "extended-join" not in updated_user.capabilities
      end)
    end

    test "handles CAP REQ command with unsupported capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "UNSUPPORTED"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} NAK :UNSUPPORTED\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert updated_user.capabilities == []
      end)
    end

    test "treats capability names as case-sensitive opaque strings" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["userhost-in-names"])

        assert :ok =
                 Cap.handle(user, %Message{
                   command: "CAP",
                   params: ["REQ", "USERHOST-IN-NAMES"]
                 })

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} NAK :USERHOST-IN-NAMES\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert updated_user.capabilities == ["userhost-in-names"]
      end)
    end

    test "does not disable a lowercase capability through an uppercase alias" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["userhost-in-names"])

        assert :ok =
                 Cap.handle(user, %Message{
                   command: "CAP",
                   params: ["REQ", "-USERHOST-IN-NAMES"]
                 })

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} NAK :-USERHOST-IN-NAMES\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert updated_user.capabilities == ["userhost-in-names"]
      end)
    end

    test "handles CAP REQ command with mixed valid and invalid capabilities" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "userhost-in-names UNSUPPORTED"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} NAK :userhost-in-names UNSUPPORTED\r\n"}
        ])

        # Verify no capabilities were added due to NAK
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert updated_user.capabilities == []
      end)
    end

    test "handles CAP REQ command that tries to enable already enabled capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["userhost-in-names"])
        message = %Message{command: "CAP", params: ["REQ", "userhost-in-names"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :userhost-in-names\r\n"}
        ])

        # Verify the capability list doesn't have duplicates
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert updated_user.capabilities == ["userhost-in-names"]
      end)
    end

    for capability <- ["uhnames", "extended-uhlist", "invite-extended", "WHOX", "whox", "monitor", "msgid"] do
      test "rejects unsupported capability #{capability} without applying other requests" do
        Memento.transaction!(fn ->
          user = insert(:user)
          request = "userhost-in-names #{unquote(capability)}"
          assert :ok = Cap.handle(user, %Message{command: "CAP", params: ["REQ", request]})
          assert_sent_messages([{user.pid, ":irc.test CAP #{user.nick} NAK :#{request}\r\n"}])
          updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
          assert updated_user.capabilities == user.capabilities
        end)
      end
    end

    test "handles CAP REQ command with message-tags capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "message-tags"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :message-tags\r\n"}
        ])

        # Verify the capability was added to the user
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert "message-tags" in updated_user.capabilities
      end)
    end

    test "handles CAP REQ command with echo-message capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "echo-message"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :echo-message\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert "echo-message" in updated_user.capabilities
      end)
    end

    test "handles CAP REQ command with BATCH and LABELED-RESPONSE capabilities" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "batch labeled-response"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :batch labeled-response\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert "batch" in updated_user.capabilities
        assert "labeled-response" in updated_user.capabilities
      end)
    end

    test "rejects capabilities disabled in the server configuration as one atomic request" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        original_config
        |> Keyword.put(:batch, false)
        |> Keyword.put(:labeled_response, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "batch labeled-response"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} NAK :batch labeled-response\r\n"}
        ])

        assert Memento.Query.read(ElixIRCd.Tables.User, user.uid).capabilities == []
      end)
    end

    test "does not advertise or accept labeled-response when its batch dependency is disabled" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || [])
        |> Keyword.put(:batch, false)
        |> Keyword.put(:labeled_response, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])

        assert :ok = Cap.handle(user, %Message{command: "CAP", params: ["LS"]})

        assert_sent_messages([
          {user.pid, ~r/^:irc\.test CAP .* LS :(?!.*(?:batch|labeled-response)).*\r\n$/}
        ])

        assert :ok = Cap.handle(user, %Message{command: "CAP", params: ["REQ", "labeled-response"]})

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} NAK :labeled-response\r\n"}
        ])
      end)
    end

    for capability <- ["batch", "labeled-response"] do
      test "sends a labeled CAP ACK before disabling #{capability}" do
        capability = unquote(capability)
        test_pid = self()
        message_agent = @agent_name

        Mimic.stub(Connection, :handle_send, fn pid, wire_message ->
          [persisted_user] = Memento.Query.select(ElixIRCd.Tables.User, {:==, :pid, pid}, limit: 1)
          send(test_pid, {:capabilities_when_sent, persisted_user.capabilities})
          Agent.update(message_agent, fn messages -> [{pid, wire_message} | messages] end)
        end)

        Memento.transaction!(fn ->
          user = insert(:user, capabilities: ["batch", "labeled-response"])

          message = %Message{
            command: "CAP",
            params: ["REQ", "-#{capability}"],
            tags: %{"label" => "disable-cap"}
          }

          assert :ok = ResponseContext.with_command(user, message, fn -> Cap.handle(user, message) end)

          assert_received {:capabilities_when_sent, capabilities_at_send}
          assert "batch" in capabilities_at_send
          assert "labeled-response" in capabilities_at_send

          assert_sent_messages([
            {user.pid, "@label=disable-cap :irc.test CAP #{user.nick} ACK :-#{capability}\r\n"}
          ])

          refute capability in Memento.Query.read(ElixIRCd.Tables.User, user.uid).capabilities
        end)
      end
    end

    test "negotiates standard-replies independently per connection through its full lifecycle" do
      Memento.transaction!(fn ->
        first = insert(:user, registered: false, capabilities: [])
        second = insert(:user, capabilities: [])
        assert :ok = Cap.handle(first, %Message{command: "CAP", params: ["LS", "302"]})
        assert_sent_message_contains(first.pid, ~r/ LS :.* standard-replies(?: |\r)/)
        {:ok, first} = Users.get_by_pid(first.pid)
        assert :ok = Cap.handle(first, %Message{command: "CAP", params: ["REQ"], trailing: "standard-replies"})
        {:ok, first} = Users.get_by_pid(first.pid)
        assert "standard-replies" in first.capabilities
        {:ok, second} = Users.get_by_pid(second.pid)
        refute "standard-replies" in second.capabilities
        assert :ok = Cap.handle(first, %Message{command: "CAP", params: ["LIST"]})
        assert_sent_message_contains(first.pid, ":irc.test CAP * LIST :standard-replies cap-notify\r\n")
        assert :ok = Cap.handle(first, %Message{command: "CAP", params: ["REQ"], trailing: "-standard-replies"})
        {:ok, first} = Users.get_by_pid(first.pid)
        refute "standard-replies" in first.capabilities
        assert_sent_message_contains(first.pid, ":irc.test CAP * ACK :-standard-replies\r\n")
        assert_sent_messages_amount(second.pid, 0)
      end)
    end

    test "rejects standard-replies requests atomically when disabled" do
      original = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original) end)
      Application.put_env(:elixircd, :capabilities, Keyword.put(original, :standard_replies, false))

      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        Cap.handle(user, %Message{command: "CAP", params: ["LS"]})
        assert_sent_messages_count_containing(user.pid, ~r/standard-replies/, 0)
        Cap.handle(user, %Message{command: "CAP", params: ["REQ"], trailing: "setname standard-replies"})
        assert_sent_message_contains(user.pid, ":irc.test CAP #{user.nick} NAK :setname standard-replies\r\n")
        {:ok, updated} = Users.get_by_pid(user.pid)
        assert updated.capabilities == []
      end)
    end

    test "rejects noncanonical standard-replies capability names" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        Cap.handle(user, %Message{command: "CAP", params: ["REQ"], trailing: "Standard-Replies"})
        assert_sent_messages([{user.pid, ":irc.test CAP #{user.nick} NAK :Standard-Replies\r\n"}])
      end)
    end
  end

  describe "handle/2 - CAP END" do
    test "handles CAP END command" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CAP", params: ["END"]}

        assert :ok = Cap.handle(user, message)

        # CAP END should not send any response
        assert_sent_messages([])
      end)
    end

    test "CAP END disables cap_negotiating flag" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, cap_negotiating: true)
        message = %Message{command: "CAP", params: ["END"]}

        assert :ok = Cap.handle(user, message)

        # Verify cap_negotiating was set to false
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert updated_user.cap_negotiating == false
      end)
    end

    test "CAP END triggers handshake when user has NICK and USER set" do
      Memento.transaction!(fn ->
        user =
          insert(:user,
            registered: false,
            cap_negotiating: true,
            nick: "testnick",
            ident: "~testuser",
            realname: "Test User"
          )

        message = %Message{command: "CAP", params: ["END"]}

        assert :ok = Cap.handle(user, message)

        # Verify cap_negotiating was set to false
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert updated_user.cap_negotiating == false

        # Handshake should have been triggered (user should be registered)
        assert updated_user.registered == true
      end)
    end

    test "CAP END after registration does not re-run the handshake" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: true, cap_negotiating: false)
        message = %Message{command: "CAP", params: ["END"]}

        assert :ok = Cap.handle(user, message)

        # 001 and friends must be sent exactly once.
        assert_sent_messages_amount(user.pid, 0)
      end)
    end
  end

  describe "handle/2 - Unsupported CAP commands" do
    test "handles unsupported CAP commands" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CAP", params: ["UNKNOWN", "param"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 410 #{user.nick} UNKNOWN :Invalid CAP subcommand\r\n"}
        ])
      end)
    end
  end

  describe "SASL mechanism handling" do
    test "handles SASL with explicitly enabled PLAIN" do
      original_caps = Application.get_env(:elixircd, :capabilities)
      original_sasl = Application.get_env(:elixircd, :sasl)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, original_caps)
        Application.put_env(:elixircd, :sasl, original_sasl)
      end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_caps || [])
        |> Keyword.put(:account_tag, true)
        |> Keyword.put(:sasl, true)
      )

      # Provide the complete SASL configuration.
      Application.put_env(:elixircd, :sasl,
        plain: [enabled: true, require_tls: true],
        session_timeout_ms: 60_000,
        max_attempts_per_connection: 3
      )

      Memento.transaction!(fn ->
        user = insert(:user, transport: :tls)
        message = %Message{command: "CAP", params: ["LS", "302"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_message_contains(user.pid, ~r/sasl=PLAIN/)
      end)
    end

    test "does not advertise PLAIN on an insecure transport when TLS is required" do
      original_caps = Application.get_env(:elixircd, :capabilities)
      original_sasl = Application.get_env(:elixircd, :sasl)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, original_caps)
        Application.put_env(:elixircd, :sasl, original_sasl)
      end)

      Application.put_env(:elixircd, :capabilities, Keyword.put(original_caps, :sasl, true))

      Application.put_env(
        :elixircd,
        :sasl,
        plain: [enabled: true, require_tls: true],
        scram_sha_256: [enabled: false],
        ecdsa: [enabled: false]
      )

      Memento.transaction!(fn ->
        user = insert(:user, transport: :tcp)
        assert :ok = Cap.handle(user, %Message{command: "CAP", params: ["LS", "302"]})
        assert_sent_message_contains(user.pid, ~r/ CAP .* LS :/)
        assert_sent_messages_count_containing(user.pid, ~r/sasl=/, 0)
      end)
    end

    test "notifies CAP DEL and CAP NEW when native authority availability changes" do
      Memento.transaction!(fn ->
        user = insert(:user, transport: :tls, capabilities: ["sasl"], cap_version: 302)
        old_runtime = %{sid: "leaf", services_authority: "root", reachable_sids: MapSet.new(["leaf", "root"])}
        unavailable_runtime = %{old_runtime | reachable_sids: MapSet.new(["leaf"])}

        old_capabilities = Cap.capability_map(user, old_runtime)
        assert :ok = Cap.notify_dynamic_changes(%{user.pid => old_capabilities}, unavailable_runtime)
        assert_sent_message_contains(user.pid, ~r/ CAP .* DEL :sasl\r\n/)

        {:ok, updated} = Users.get_by_pid(user.pid)
        refute "sasl" in updated.capabilities

        assert :ok =
                 Cap.notify_dynamic_changes(%{user.pid => Map.delete(old_capabilities, "sasl")}, old_runtime)

        assert_sent_message_contains(user.pid, ~r/ CAP .* NEW :sasl=PLAIN\r\n/)
      end)
    end

    test "aborts a live remote SASL session when authority availability is withdrawn" do
      Memento.transaction!(fn ->
        user = insert(:user, transport: :tls, capabilities: ["sasl"], cap_version: 302)

        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          state: %{
            remote_sasl: %{
              authority: "root",
              attempt_id: ElixIRCd.Server.S2S.Identity.nonce(),
              mechanism: "PLAIN",
              step: 1,
              pending?: true
            }
          }
        })

        old_runtime = %{sid: "leaf", services_authority: "root", reachable_sids: MapSet.new(["leaf", "root"])}
        unavailable_runtime = %{old_runtime | reachable_sids: MapSet.new(["leaf"])}
        old_capabilities = Cap.capability_map(user, old_runtime)

        assert :ok = Cap.notify_dynamic_changes(%{user.pid => old_capabilities}, unavailable_runtime)
        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
        assert_sent_message_contains(user.pid, ~r/SASL authentication authority is unavailable/)
      end)
    end
  end

  describe "sts (Strict Transport Security) capability" do
    test "announces sts=port on plaintext (tcp) connections" do
      original_caps = Application.get_env(:elixircd, :capabilities)
      original_sts = Application.get_env(:elixircd, :sts)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, original_caps)
        Application.put_env(:elixircd, :sts, original_sts)
      end)

      Application.put_env(:elixircd, :capabilities, (original_caps || []) |> Keyword.put(:sts, true))
      Application.put_env(:elixircd, :sts, port: 6697, duration: 2_592_000, preload: false)

      Memento.transaction!(fn ->
        user = insert(:user, transport: :tcp)
        message = %Message{command: "CAP", params: ["LS", "302"]}

        assert :ok = Cap.handle(user, message)

        # Verify the response contains sts with port announcement
        assert_sent_message_contains(user.pid, ~r/sts=port=6697/)
      end)
    end

    test "announces sts=duration on TLS connections" do
      original_caps = Application.get_env(:elixircd, :capabilities)
      original_sts = Application.get_env(:elixircd, :sts)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, original_caps)
        Application.put_env(:elixircd, :sts, original_sts)
      end)

      Application.put_env(:elixircd, :capabilities, (original_caps || []) |> Keyword.put(:sts, true))
      Application.put_env(:elixircd, :sts, port: 6697, duration: 2_592_000, preload: false)

      Memento.transaction!(fn ->
        user = insert(:user, transport: :tls)
        message = %Message{command: "CAP", params: ["LS", "302"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_message_contains(user.pid, ~r/sts=duration=2592000/)
      end)
    end

    test "announces sts=duration,preload on TLS when preload is enabled" do
      original_caps = Application.get_env(:elixircd, :capabilities)
      original_sts = Application.get_env(:elixircd, :sts)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, original_caps)
        Application.put_env(:elixircd, :sts, original_sts)
      end)

      Application.put_env(:elixircd, :capabilities, (original_caps || []) |> Keyword.put(:sts, true))
      Application.put_env(:elixircd, :sts, port: 6697, duration: 2_592_000, preload: true)

      Memento.transaction!(fn ->
        user = insert(:user, transport: :tls)
        message = %Message{command: "CAP", params: ["LS", "302"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_message_contains(user.pid, ~r/sts=duration=2592000,preload/)
      end)
    end

    test "announces sts=port on WebSocket connections" do
      original_caps = Application.get_env(:elixircd, :capabilities)
      original_sts = Application.get_env(:elixircd, :sts)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, original_caps)
        Application.put_env(:elixircd, :sts, original_sts)
      end)

      Application.put_env(:elixircd, :capabilities, (original_caps || []) |> Keyword.put(:sts, true))
      Application.put_env(:elixircd, :sts, port: 6697, duration: 2_592_000, preload: false)

      Memento.transaction!(fn ->
        user = insert(:user, transport: :ws)
        message = %Message{command: "CAP", params: ["LS", "302"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_message_contains(user.pid, ~r/sts=port=6697/)
      end)
    end

    test "announces sts=duration on secure WebSocket connections" do
      original_caps = Application.get_env(:elixircd, :capabilities)
      original_sts = Application.get_env(:elixircd, :sts)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, original_caps)
        Application.put_env(:elixircd, :sts, original_sts)
      end)

      Application.put_env(:elixircd, :capabilities, (original_caps || []) |> Keyword.put(:sts, true))
      Application.put_env(:elixircd, :sts, port: 6697, duration: 2_592_000, preload: false)

      Memento.transaction!(fn ->
        user = insert(:user, transport: :wss)
        message = %Message{command: "CAP", params: ["LS", "302"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_message_contains(user.pid, ~r/sts=duration=2592000/)
      end)
    end

    test "does not announce sts when capability is disabled" do
      original_caps = Application.get_env(:elixircd, :capabilities)
      original_sts = Application.get_env(:elixircd, :sts)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, original_caps)
        Application.put_env(:elixircd, :sts, original_sts)
      end)

      Application.put_env(:elixircd, :capabilities, (original_caps || []) |> Keyword.put(:sts, false))
      Application.put_env(:elixircd, :sts, port: 6697, duration: 2_592_000, preload: false)

      Memento.transaction!(fn ->
        user = insert(:user, transport: :tcp)
        message = %Message{command: "CAP", params: ["LS", "302"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages_amount(user.pid, 1)
      end)
    end

    test "rejects CAP REQ sts with NAK" do
      original_caps = Application.get_env(:elixircd, :capabilities)
      original_sts = Application.get_env(:elixircd, :sts)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, original_caps)
        Application.put_env(:elixircd, :sts, original_sts)
      end)

      Application.put_env(:elixircd, :capabilities, (original_caps || []) |> Keyword.put(:sts, true))
      Application.put_env(:elixircd, :sts, port: 6697, duration: 2_592_000, preload: false)

      Memento.transaction!(fn ->
        user = insert(:user, transport: :tls, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "sts"]}

        assert :ok = Cap.handle(user, message)

        # Should return NAK as per IRCv3 spec - clients cannot request sts
        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} NAK :sts\r\n"}
        ])

        # Verify sts was not added to user capabilities
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert "sts" not in updated_user.capabilities
      end)
    end

    test "rejects CAP REQ sts even when combined with valid capabilities" do
      original_caps = Application.get_env(:elixircd, :capabilities)
      original_sts = Application.get_env(:elixircd, :sts)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, original_caps)
        Application.put_env(:elixircd, :sts, original_sts)
      end)

      Application.put_env(:elixircd, :capabilities, (original_caps || []) |> Keyword.put(:sts, true))
      Application.put_env(:elixircd, :sts, port: 6697, duration: 2_592_000, preload: false)

      Memento.transaction!(fn ->
        user = insert(:user, transport: :tls, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "userhost-in-names sts"]}

        assert :ok = Cap.handle(user, message)

        # Should return NAK because sts is in the request
        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} NAK :userhost-in-names sts\r\n"}
        ])

        # Verify neither capability was added
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert updated_user.capabilities == []
      end)
    end

    test "does not announce sts when duration is nil on TLS connections" do
      original_caps = Application.get_env(:elixircd, :capabilities)
      original_sts = Application.get_env(:elixircd, :sts)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, original_caps)
        Application.put_env(:elixircd, :sts, original_sts)
      end)

      Application.put_env(:elixircd, :capabilities, (original_caps || []) |> Keyword.put(:sts, true))
      Application.put_env(:elixircd, :sts, port: 6697, duration: nil, preload: false)

      Memento.transaction!(fn ->
        user = insert(:user, transport: :tls)
        message = %Message{command: "CAP", params: ["LS", "302"]}

        assert :ok = Cap.handle(user, message)

        # Should not include sts in the response when duration is nil
        assert_sent_messages_count_containing(user.pid, ~r/sts=/, 0)
      end)
    end

    test "announces duration zero to revoke an STS persistence policy" do
      original_caps = Application.get_env(:elixircd, :capabilities)
      original_sts = Application.get_env(:elixircd, :sts)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, original_caps)
        Application.put_env(:elixircd, :sts, original_sts)
      end)

      Application.put_env(:elixircd, :capabilities, (original_caps || []) |> Keyword.put(:sts, true))
      Application.put_env(:elixircd, :sts, port: 6697, duration: 0, preload: false)

      Memento.transaction!(fn ->
        user = insert(:user, transport: :tls)
        message = %Message{command: "CAP", params: ["LS", "302"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_message_contains(user.pid, ~r/sts=duration=0/)
      end)
    end

    test "does not announce sts when port is nil on plaintext connections" do
      original_caps = Application.get_env(:elixircd, :capabilities)
      original_sts = Application.get_env(:elixircd, :sts)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, original_caps)
        Application.put_env(:elixircd, :sts, original_sts)
      end)

      Application.put_env(:elixircd, :capabilities, (original_caps || []) |> Keyword.put(:sts, true))
      Application.put_env(:elixircd, :sts, port: nil, duration: 2_592_000, preload: false)

      Memento.transaction!(fn ->
        user = insert(:user, transport: :tcp)
        message = %Message{command: "CAP", params: ["LS", "302"]}

        assert :ok = Cap.handle(user, message)

        # Should not include sts in the response when port is nil
        assert_sent_messages_count_containing(user.pid, ~r/sts=/, 0)
      end)
    end
  end

  describe "cap-notify capability" do
    test "announces cap-notify when enabled in config" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || [])
        |> Keyword.put(:cap_notify, true)
        |> Keyword.put(:sts, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CAP", params: ["LS", "302"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_message_contains(user.pid, ~r/cap-notify/)
      end)
    end

    test "does not announce cap-notify when disabled in config" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || [])
        |> Keyword.put(:cap_notify, false)
        |> Keyword.put(:sts, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages_count_containing(user.pid, ~r/cap-notify/, 0)
      end)
    end

    test "allows requesting cap-notify capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "cap-notify"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :cap-notify\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert "cap-notify" in updated_user.capabilities
      end)
    end

    test "allows disabling cap-notify capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["cap-notify"])
        message = %Message{command: "CAP", params: ["REQ", "-cap-notify"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :-cap-notify\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.uid)
        assert "cap-notify" not in updated_user.capabilities
      end)
    end

    test "advertises account-registration feature values for CAP 302" do
      original = Application.fetch_env!(:elixircd, :account_registration)
      on_exit(fn -> Application.put_env(:elixircd, :account_registration, original) end)
      Application.put_env(:elixircd, :account_registration, Keyword.put(original, :before_connect, true))

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        assert :ok = Cap.handle(user, %Message{command: "CAP", params: ["LS", "302"]})
        assert_sent_message_contains(user.pid, ~r/draft\/account-registration=before-connect/)
      end)
    end
  end
end
