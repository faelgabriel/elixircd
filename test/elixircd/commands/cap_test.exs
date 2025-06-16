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
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP * LS :EXTENDED-UHLIST UHNAMES\r\n"}
        ])
      end)
    end

    test "handles CAP LS command for listing supported capabilities for IRCv3.2" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "CAP", params: ["LS", "302"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP * LS :EXTENDED-UHLIST UHNAMES\r\n"}
        ])
      end)
    end

    test "handles CAP LS when extended names are disabled" do
      original_config = Application.get_env(:elixircd, :capabilities)
      Application.put_env(:elixircd, :capabilities, Keyword.put(original_config, :extended_names, false))

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} LS :EXTENDED-UHLIST\r\n"}
        ])
      end)

      Application.put_env(:elixircd, :capabilities, original_config)
    end

    test "handles CAP LS when extended uhlist is disabled" do
      original_config = Application.get_env(:elixircd, :capabilities)

      Application.put_env(
        :elixircd,
        :capabilities,
        original_config
        |> Keyword.put(:extended_names, false)
        |> Keyword.put(:extended_uhlist, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "CAP", params: ["LS"]}

        assert :ok = Cap.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test CAP #{user.nick} LS :\r\n"}
        ])
      end)

      Application.put_env(:elixircd, :capabilities, original_config)
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
end
