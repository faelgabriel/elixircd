defmodule ElixIRCd.Commands.CapTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Cap
  alias ElixIRCd.Message

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
        |> Keyword.put(:chghost, true)
        |> Keyword.put(:client_tags, true)
        |> Keyword.put(:multi_prefix, true)
        |> Keyword.put(:setname, true)
        |> Keyword.put(:extended_names, true)
        |> Keyword.put(:extended_uhlist, true)
        |> Keyword.put(:message_tags, true)
        |> Keyword.put(:server_time, true)
        |> Keyword.put(:msgid, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test CAP * LS :ACCOUNT-TAG ACCOUNT-NOTIFY AWAY-NOTIFY CHGHOST CLIENT-TAGS MULTI-PREFIX SASL=PLAIN SETNAME MSGID SERVER-TIME MESSAGE-TAGS EXTENDED-UHLIST UHNAMES\r\n"}
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
        |> Keyword.put(:chghost, true)
        |> Keyword.put(:client_tags, true)
        |> Keyword.put(:multi_prefix, true)
        |> Keyword.put(:setname, true)
        |> Keyword.put(:extended_names, true)
        |> Keyword.put(:extended_uhlist, true)
        |> Keyword.put(:message_tags, true)
        |> Keyword.put(:server_time, true)
        |> Keyword.put(:msgid, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "CAP", params: ["LS", "302"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test CAP * LS :ACCOUNT-TAG ACCOUNT-NOTIFY AWAY-NOTIFY CHGHOST CLIENT-TAGS MULTI-PREFIX SASL=PLAIN SETNAME MSGID SERVER-TIME MESSAGE-TAGS EXTENDED-UHLIST UHNAMES\r\n"}
        ])
      end)
    end

    test "handles CAP LS when extended names are disabled" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        original_config
        |> Keyword.put(:account_tag, true)
        |> Keyword.put(:account_notify, true)
        |> Keyword.put(:away_notify, true)
        |> Keyword.put(:chghost, true)
        |> Keyword.put(:client_tags, true)
        |> Keyword.put(:multi_prefix, true)
        |> Keyword.put(:setname, true)
        |> Keyword.put(:extended_names, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test CAP #{user.nick} LS :ACCOUNT-TAG ACCOUNT-NOTIFY AWAY-NOTIFY CHGHOST CLIENT-TAGS MULTI-PREFIX SASL=PLAIN SETNAME MSGID SERVER-TIME MESSAGE-TAGS EXTENDED-UHLIST\r\n"}
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
        |> Keyword.put(:chghost, true)
        |> Keyword.put(:client_tags, true)
        |> Keyword.put(:multi_prefix, true)
        |> Keyword.put(:setname, true)
        |> Keyword.put(:extended_names, false)
        |> Keyword.put(:extended_uhlist, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test CAP #{user.nick} LS :ACCOUNT-TAG ACCOUNT-NOTIFY AWAY-NOTIFY CHGHOST CLIENT-TAGS MULTI-PREFIX SASL=PLAIN SETNAME MSGID SERVER-TIME MESSAGE-TAGS\r\n"}
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
        |> Keyword.put(:chghost, false)
        |> Keyword.put(:client_tags, false)
        |> Keyword.put(:multi_prefix, false)
        |> Keyword.put(:setname, false)
        |> Keyword.put(:extended_names, false)
        |> Keyword.put(:extended_uhlist, false)
        |> Keyword.put(:message_tags, false)
        |> Keyword.put(:server_time, false)
        |> Keyword.put(:msgid, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} LS :SASL=PLAIN\r\n"}
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
        |> Keyword.put(:sasl, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test CAP #{user.nick} LS :ACCOUNT-TAG ACCOUNT-NOTIFY AWAY-NOTIFY CHGHOST CLIENT-TAGS MULTI-PREFIX SETNAME MSGID SERVER-TIME MESSAGE-TAGS EXTENDED-UHLIST UHNAMES\r\n"}
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
        |> Keyword.put(:sasl, true)
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
           ":irc.test CAP #{user.nick} LS :ACCOUNT-TAG ACCOUNT-NOTIFY AWAY-NOTIFY CHGHOST CLIENT-TAGS MULTI-PREFIX SETNAME MSGID SERVER-TIME MESSAGE-TAGS EXTENDED-UHLIST UHNAMES\r\n"}
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

    test "handles CAP LIST command with UHNAMES capability enabled" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["UHNAMES"])
        message = %Message{command: "CAP", params: ["LIST"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} LIST :UHNAMES\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - CAP REQ" do
    test "handles CAP REQ command to request UHNAMES capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "UHNAMES"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :UHNAMES\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert "UHNAMES" in updated_user.capabilities
      end)
    end

    test "handles CAP REQ command with trailing parameter" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ"], trailing: "UHNAMES"}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :UHNAMES\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert "UHNAMES" in updated_user.capabilities
      end)
    end

    test "handles CAP REQ command to disable UHNAMES capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["UHNAMES"])
        message = %Message{command: "CAP", params: ["REQ", "-UHNAMES"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :-UHNAMES\r\n"}
        ])

        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert "UHNAMES" not in updated_user.capabilities
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

    test "handles CAP REQ command with mixed valid and invalid capabilities" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "UHNAMES UNSUPPORTED"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} NAK :UHNAMES UNSUPPORTED\r\n"}
        ])

        # Verify no capabilities were added due to NAK
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert updated_user.capabilities == []
      end)
    end

    test "handles CAP REQ command that tries to enable already enabled capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: ["UHNAMES"])
        message = %Message{command: "CAP", params: ["REQ", "UHNAMES"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :UHNAMES\r\n"}
        ])

        # Verify the capability list doesn't have duplicates
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert updated_user.capabilities == ["UHNAMES"]
      end)
    end

    test "handles CAP REQ command with EXTENDED-UHLIST capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "EXTENDED-UHLIST"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :EXTENDED-UHLIST\r\n"}
        ])

        # Verify the capability was added to the user
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert "EXTENDED-UHLIST" in updated_user.capabilities
      end)
    end

    test "handles CAP REQ command with MESSAGE-TAGS capability" do
      Memento.transaction!(fn ->
        user = insert(:user, capabilities: [])
        message = %Message{command: "CAP", params: ["REQ", "MESSAGE-TAGS"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} ACK :MESSAGE-TAGS\r\n"}
        ])

        # Verify the capability was added to the user
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert "MESSAGE-TAGS" in updated_user.capabilities
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
end
