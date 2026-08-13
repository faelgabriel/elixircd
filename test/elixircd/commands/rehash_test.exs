defmodule ElixIRCd.Commands.RehashTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Rehash
  alias ElixIRCd.Message
  alias ElixIRCd.Utils.System

  describe "handle/2" do
    test "handles REHASH command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "REHASH", params: ["#anything"]}

        assert :ok = Rehash.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles REHASH command with user not operator" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "REHASH", params: []}

        assert :ok = Rehash.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 481 #{user.nick} :Permission Denied- You're not an IRC operator\r\n"}
        ])
      end)
    end

    test "handles REHASH command with user operator" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        message = %Message{command: "REHASH", params: []}

        assert :ok = Rehash.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 382 #{user.nick} elixircd.exs :Rehashing\r\n"},
          {user.pid, ":irc.test NOTICE #{user.nick} :Rehashing completed\r\n"}
        ])
      end)
    end
  end

  describe "capability notifications during REHASH" do
    setup do
      original_config = Application.get_env(:elixircd, :capabilities)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, original_config)
      end)

      %{original_config: original_config}
    end

    test "notifies clients when capability is enabled", %{original_config: original_config} do
      Application.put_env(:elixircd, :capabilities, (original_config || []) |> Keyword.put(:invite_notify, false))

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])
        client = insert(:user, capabilities: ["cap-notify"], registered: true)

        System
        |> stub(:load_configurations, fn ->
          Application.put_env(
            :elixircd,
            :capabilities,
            Application.get_env(:elixircd, :capabilities, []) |> Keyword.put(:invite_notify, true)
          )
        end)

        assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})

        assert_sent_message_contains(client.pid, ~r/CAP .* NEW :invite-notify/)
      end)
    end

    test "notifies clients when capability is disabled", %{original_config: original_config} do
      Application.put_env(:elixircd, :capabilities, (original_config || []) |> Keyword.put(:away_notify, true))

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])
        client = insert(:user, capabilities: ["cap-notify", "away-notify"], registered: true)

        System
        |> stub(:load_configurations, fn ->
          Application.put_env(
            :elixircd,
            :capabilities,
            Application.get_env(:elixircd, :capabilities, []) |> Keyword.put(:away_notify, false)
          )
        end)

        assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})

        assert_sent_message_contains(client.pid, ~r/CAP .* DEL :away-notify/)

        updated_client = Memento.Query.read(ElixIRCd.Tables.User, client.pid)
        assert "away-notify" not in updated_client.capabilities
        assert "cap-notify" in updated_client.capabilities
      end)
    end

    test "notifies multiple capability changes simultaneously", %{original_config: original_config} do
      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:extended_join, false) |> Keyword.put(:chghost, false)
      )

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])
        client = insert(:user, capabilities: ["cap-notify"], registered: true)

        System
        |> stub(:load_configurations, fn ->
          Application.put_env(
            :elixircd,
            :capabilities,
            Application.get_env(:elixircd, :capabilities, [])
            |> Keyword.put(:extended_join, true)
            |> Keyword.put(:chghost, true)
          )
        end)

        assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})

        assert_sent_message_contains(client.pid, ~r/CAP .* NEW :.*extended-join/)
        assert_sent_message_contains(client.pid, ~r/CAP .* NEW :.*chghost/)
      end)
    end

    test "does not notify when no capabilities change", %{original_config: original_config} do
      Application.put_env(:elixircd, :capabilities, (original_config || []) |> Keyword.put(:setname, true))

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])
        client = insert(:user, capabilities: ["cap-notify"], registered: true)

        System
        |> stub(:load_configurations, fn ->
          Application.put_env(
            :elixircd,
            :capabilities,
            Application.get_env(:elixircd, :capabilities, []) |> Keyword.put(:setname, true)
          )
        end)

        assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})

        assert_sent_messages_amount(oper.pid, 2)
        refute_received {^client, _}
      end)
    end

    test "only notifies users with cap-notify enabled", %{original_config: original_config} do
      Application.put_env(:elixircd, :capabilities, (original_config || []) |> Keyword.put(:multi_prefix, false))

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])
        client_with_cap = insert(:user, capabilities: ["cap-notify"], registered: true)
        client_without_cap = insert(:user, capabilities: [], registered: true)

        System
        |> stub(:load_configurations, fn ->
          Application.put_env(
            :elixircd,
            :capabilities,
            Application.get_env(:elixircd, :capabilities, []) |> Keyword.put(:multi_prefix, true)
          )
        end)

        assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})

        assert_sent_message_contains(client_with_cap.pid, ~r/CAP .* NEW :multi-prefix/)
        refute_received {^client_without_cap, _}
      end)
    end

    test "broadcasts to all users with cap-notify", %{original_config: original_config} do
      Application.put_env(:elixircd, :capabilities, (original_config || []) |> Keyword.put(:account_notify, false))

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])
        client1 = insert(:user, capabilities: ["cap-notify"], registered: true)
        client2 = insert(:user, capabilities: ["cap-notify"], registered: true)

        System
        |> stub(:load_configurations, fn ->
          Application.put_env(
            :elixircd,
            :capabilities,
            Application.get_env(:elixircd, :capabilities, []) |> Keyword.put(:account_notify, true)
          )
        end)

        assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})

        assert_sent_message_contains(client1.pid, ~r/CAP .* NEW :account-notify/)
        assert_sent_message_contains(client2.pid, ~r/CAP .* NEW :account-notify/)
      end)
    end

    test "removes deleted capabilities from users", %{original_config: original_config} do
      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:server_time, true) |> Keyword.put(:msgid, true)
      )

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])
        client = insert(:user, capabilities: ["cap-notify", "server-time", "msgid"], registered: true)

        System
        |> stub(:load_configurations, fn ->
          Application.put_env(
            :elixircd,
            :capabilities,
            Application.get_env(:elixircd, :capabilities, [])
            |> Keyword.put(:server_time, false)
            |> Keyword.put(:msgid, false)
          )
        end)

        assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})

        assert_sent_message_contains(client.pid, ~r/CAP .* DEL :.*server-time/)
        assert_sent_message_contains(client.pid, ~r/CAP .* DEL :.*msgid/)

        updated_client = Memento.Query.read(ElixIRCd.Tables.User, client.pid)
        assert "server-time" not in updated_client.capabilities
        assert "msgid" not in updated_client.capabilities
        assert "cap-notify" in updated_client.capabilities
      end)
    end
  end
end
