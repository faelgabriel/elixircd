defmodule ElixIRCd.Commands.CapTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Cap
  alias ElixIRCd.Message
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
        |> Keyword.put(:invite_extended, true)
        |> Keyword.put(:invite_notify, true)
        |> Keyword.put(:multi_prefix, true)
        |> Keyword.put(:setname, true)
        |> Keyword.put(:extended_names, true)
        |> Keyword.put(:extended_uhlist, true)
        |> Keyword.put(:message_tags, true)
        |> Keyword.put(:server_time, true)
        |> Keyword.put(:msgid, true)
        |> Keyword.put(:sts, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test CAP * LS :account-tag account-notify away-notify batch chghost echo-message extended-join invite-extended invite-notify labeled-response multi-prefix sasl=PLAIN setname msgid server-time message-tags extended-uhlist uhnames monitor\r\n"}
        ])
      end)
    end

    test "CAP LS enables cap_negotiating flag on first call" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, cap_negotiating: nil)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        # Verify cap_negotiating was set to true
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert updated_user.cap_negotiating == true
      end)
    end

    test "CAP LS keeps cap_negotiating enabled if already active" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, cap_negotiating: true)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        # Verify cap_negotiating is still true
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
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
        |> Keyword.put(:invite_extended, true)
        |> Keyword.put(:invite_notify, true)
        |> Keyword.put(:multi_prefix, true)
        |> Keyword.put(:setname, true)
        |> Keyword.put(:extended_names, true)
        |> Keyword.put(:extended_uhlist, true)
        |> Keyword.put(:message_tags, true)
        |> Keyword.put(:server_time, true)
        |> Keyword.put(:msgid, true)
        |> Keyword.put(:sts, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "CAP", params: ["LS", "302"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test CAP * LS :account-tag account-notify away-notify batch chghost echo-message extended-join invite-extended invite-notify labeled-response multi-prefix sasl=PLAIN setname msgid server-time message-tags extended-uhlist uhnames monitor\r\n"}
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
        |> Keyword.put(:invite_extended, true)
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
           ":irc.test CAP #{user.nick} LS :account-tag account-notify away-notify batch chghost echo-message extended-join invite-extended invite-notify labeled-response multi-prefix sasl=PLAIN setname msgid server-time message-tags extended-uhlist monitor\r\n"}
        ])
      end)
    end

    test "handles CAP LS when extended uhlist is disabled" do
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
        |> Keyword.put(:invite_extended, true)
        |> Keyword.put(:invite_notify, true)
        |> Keyword.put(:multi_prefix, true)
        |> Keyword.put(:setname, true)
        |> Keyword.put(:extended_names, false)
        |> Keyword.put(:extended_uhlist, false)
        |> Keyword.put(:sts, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test CAP #{user.nick} LS :account-tag account-notify away-notify batch chghost echo-message extended-join invite-extended invite-notify labeled-response multi-prefix sasl=PLAIN setname msgid server-time message-tags monitor\r\n"}
        ])
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
        |> Keyword.put(:away_notify, false)
        |> Keyword.put(:batch, false)
        |> Keyword.put(:cap_notify, false)
        |> Keyword.put(:chghost, false)
        |> Keyword.put(:echo_message, false)
        |> Keyword.put(:extended_join, false)
        |> Keyword.put(:invite_extended, false)
        |> Keyword.put(:invite_notify, false)
        |> Keyword.put(:multi_prefix, false)
        |> Keyword.put(:setname, false)
        |> Keyword.put(:extended_names, false)
        |> Keyword.put(:extended_uhlist, false)
        |> Keyword.put(:message_tags, false)
        |> Keyword.put(:server_time, false)
        |> Keyword.put(:msgid, false)
        |> Keyword.put(:labeled_response, false)
        |> Keyword.put(:sts, false)
        |> Keyword.put(:monitor, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} LS :sasl=PLAIN\r\n"}
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
        |> Keyword.put(:invite_extended, true)
        |> Keyword.put(:invite_notify, true)
        |> Keyword.put(:multi_prefix, true)
        |> Keyword.put(:setname, true)
        |> Keyword.put(:msgid, true)
        |> Keyword.put(:server_time, true)
        |> Keyword.put(:message_tags, true)
        |> Keyword.put(:extended_uhlist, true)
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
           ":irc.test CAP #{user.nick} LS :account-tag account-notify away-notify batch chghost echo-message extended-join invite-extended invite-notify labeled-response multi-prefix setname msgid server-time message-tags extended-uhlist uhnames monitor\r\n"}
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
        |> Keyword.put(:invite_extended, true)
        |> Keyword.put(:invite_notify, true)
        |> Keyword.put(:multi_prefix, true)
        |> Keyword.put(:setname, true)
        |> Keyword.put(:msgid, true)
        |> Keyword.put(:server_time, true)
        |> Keyword.put(:message_tags, true)
        |> Keyword.put(:extended_uhlist, true)
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
           ":irc.test CAP #{user.nick} LS :account-tag account-notify away-notify batch chghost echo-message extended-join invite-extended invite-notify labeled-response multi-prefix setname msgid server-time message-tags extended-uhlist uhnames monitor\r\n"}
        ])
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

    test "handles CAP LIST command with uhnames capability enabled" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["uhnames"])
        message = %Message{command: "CAP", params: ["LIST"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} LIST :uhnames\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - CAP REQ" do
    test "handles CAP REQ command to request uhnames capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "uhnames"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :uhnames\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert "uhnames" in updated_user.capabilities
      end)
    end

    test "handles CAP REQ command with trailing parameter" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ"], trailing: "uhnames"}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :uhnames\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert "uhnames" in updated_user.capabilities
      end)
    end

    test "handles CAP REQ command to disable uhnames capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["uhnames"])
        message = %Message{command: "CAP", params: ["REQ", "-uhnames"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :-uhnames\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert "uhnames" not in updated_user.capabilities
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

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
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

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
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

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert updated_user.capabilities == []
      end)
    end

    test "treats capability names as case-sensitive opaque strings" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["uhnames"])

        assert :ok =
                 Cap.handle(user, %Message{
                   command: "CAP",
                   params: ["REQ", "UHNAMES"]
                 })

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} NAK :UHNAMES\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert updated_user.capabilities == ["uhnames"]
      end)
    end

    test "does not disable a lowercase capability through an uppercase alias" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["uhnames"])

        assert :ok =
                 Cap.handle(user, %Message{
                   command: "CAP",
                   params: ["REQ", "-UHNAMES"]
                 })

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} NAK :-UHNAMES\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert updated_user.capabilities == ["uhnames"]
      end)
    end

    test "handles CAP REQ command with mixed valid and invalid capabilities" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "uhnames UNSUPPORTED"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} NAK :uhnames UNSUPPORTED\r\n"}
        ])

        # Verify no capabilities were added due to NAK
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert updated_user.capabilities == []
      end)
    end

    test "handles CAP REQ command that tries to enable already enabled capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["uhnames"])
        message = %Message{command: "CAP", params: ["REQ", "uhnames"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :uhnames\r\n"}
        ])

        # Verify the capability list doesn't have duplicates
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert updated_user.capabilities == ["uhnames"]
      end)
    end

    test "handles CAP REQ command with extended-uhlist capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "extended-uhlist"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :extended-uhlist\r\n"}
        ])

        # Verify the capability was added to the user
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert "extended-uhlist" in updated_user.capabilities
      end)
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
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
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

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
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

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
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

        assert Memento.Query.read(ElixIRCd.Tables.User, user.pid).capabilities == []
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
          persisted_user = Memento.Query.read(ElixIRCd.Tables.User, pid)
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

          refute capability in Memento.Query.read(ElixIRCd.Tables.User, user.pid).capabilities
        end)
      end
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
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
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
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert updated_user.cap_negotiating == false

        # Handshake should have been triggered (user should be registered)
        assert updated_user.registered == true
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
          {user.pid, ":irc.test CAP #{user.nick} NAK :Unsupported CAP command: UNKNOWN param\r\n"}
        ])
      end)
    end
  end

  describe "SASL mechanism handling" do
    test "handles SASL when no config is provided for PLAIN" do
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

      # Set SASL config to empty list (will use defaults - PLAIN enabled by default)
      Application.put_env(:elixircd, :sasl, [])

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        # Just verify the command executed successfully
        # The line we need to cover is the nil case in maybe_add_mechanism
        :ok
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
        message = %Message{command: "CAP", params: ["LS"]}

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
        message = %Message{command: "CAP", params: ["LS"]}

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
        message = %Message{command: "CAP", params: ["LS"]}

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
        message = %Message{command: "CAP", params: ["LS"]}

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
        message = %Message{command: "CAP", params: ["LS"]}

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
        message = %Message{command: "CAP", params: ["LS"]}

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
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
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
        message = %Message{command: "CAP", params: ["REQ", "uhnames sts"]}

        assert :ok = Cap.handle(user, message)

        # Should return NAK because sts is in the request
        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} NAK :uhnames sts\r\n"}
        ])

        # Verify neither capability was added
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
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
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        # Should not include sts in the response when duration is nil
        assert_sent_messages_count_containing(user.pid, ~r/sts=/, 0)
      end)
    end

    test "does not announce sts when duration is zero on TLS connections" do
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
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        # Should not include sts in the response when duration is 0
        assert_sent_messages_count_containing(user.pid, ~r/sts=/, 0)
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
        message = %Message{command: "CAP", params: ["LS"]}

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
        message = %Message{command: "CAP", params: ["LS"]}

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

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
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

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert "cap-notify" not in updated_user.capabilities
      end)
    end
  end
end
