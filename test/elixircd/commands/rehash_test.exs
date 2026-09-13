defmodule ElixIRCd.Commands.RehashTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory
  import ExUnit.CaptureLog

  alias ElixIRCd.Commands.Rehash
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.UserMonitors
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Utils.Isupport
  alias ElixIRCd.Utils.Nickserv
  alias ElixIRCd.Utils.System

  describe "handle/2" do
    test "accepts the local hostname case-insensitively" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        expect(System, :load_configurations, fn -> :ok end)

        assert :ok = Rehash.handle(user, %Message{command: "REHASH", params: ["IRC.TEST"]})
        assert_sent_message_contains(user.pid, ~r/ 382 /)
        assert_sent_message_contains(user.pid, ~r/Rehashing completed/)
      end)
    end

    for server <- ["irc.test", "other.server"] do
      test "checks privileges before selecting #{server}" do
        Memento.transaction!(fn ->
          user = insert(:user)
          reject(System, :load_configurations, 0)

          assert :ok = Rehash.handle(user, %Message{command: "REHASH", params: [unquote(server)]})

          assert_sent_messages([
            {user.pid, ":irc.test 481 #{user.nick} :Permission Denied- You're not an IRC operator\r\n"}
          ])
        end)
      end
    end

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
      original_config = Application.get_all_env(:elixircd)
      on_exit(fn -> Application.put_all_env(elixircd: original_config) end)

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

    test "rejects REHASH command with a server argument" do
      Memento.transaction!(fn ->
        user = insert(:user, modes: ["o"])
        message = %Message{command: "REHASH", params: ["other.server"]}

        assert :ok = Rehash.handle(user, message)

        assert_sent_messages([{user.pid, ":irc.test 402 #{user.nick} other.server :No such server\r\n"}])
      end)
    end

    for {error, options} <- [
          {File.Error, [reason: :enoent, action: "read file", path: "config/elixircd.exs"]},
          {SyntaxError, [file: "config/elixircd.exs", line: 1, description: "invalid configuration syntax"]},
          {RuntimeError, [message: "invalid configuration value"]}
        ],
        modern <- [false, true] do
      test "reports #{inspect(error)} with standard-replies=#{modern} and preserves configuration" do
        original = Application.get_env(:elixircd, :capabilities)
        exception = unquote(error).exception(unquote(options))
        expect(System, :load_configurations, fn -> raise exception end)
        previous_env = Application.get_all_env(:elixircd)

        Memento.transaction!(fn ->
          capabilities = ["cap-notify", "batch", "labeled-response"]
          capabilities = if unquote(modern), do: ["standard-replies" | capabilities], else: capabilities
          oper = insert(:user, modes: ["o"], capabilities: capabilities)
          observer = insert(:user, capabilities: ["cap-notify", "standard-replies"])
          request = %Message{command: "REHASH", params: [], tags: %{"label" => "failed"}}

          log = capture_log(fn -> assert :ok = ElixIRCd.Command.dispatch(oper, request) end)
          assert log =~ "[error]"
          assert log =~ "Failed to reload configuration during REHASH:"
          assert log =~ "** (#{inspect(unquote(error))})"
          assert log =~ Exception.message(exception)
          assert log =~ "rehash_test.exs:"
          assert log =~ ~r/lib\/elixircd\/commands\/rehash\.ex:\d+/
          assert Application.get_all_env(:elixircd) == previous_env
          assert Application.get_env(:elixircd, :capabilities) == original
          assert {:ok, ^oper} = Users.get_by_pid(oper.pid)
          assert {:ok, ^observer} = Users.get_by_pid(observer.pid)
          assert_sent_messages_amount(observer.pid, 0)
          assert_sent_message_contains(oper.pid, ~r/^@label=failed :irc.test BATCH \+/)
          assert_sent_message_contains(oper.pid, ~r/^@batch=\S+ :irc.test 382 /)
          assert_sent_message_contains(oper.pid, ~r/^:irc.test BATCH -/)
          assert_sent_messages_count_containing(oper.pid, ~r/REHASH_COMPLETE|rehash_test.exs|\*\* \(/, 0)

          response = if unquote(modern), do: "FAIL REHASH CONFIG_BAD", else: "NOTICE #{oper.nick}"

          assert_sent_message_contains(
            oper.pid,
            ~r/#{response} :Could not reload configuration\. Check config\/elixircd.exs and try again\.\r\n$/
          )

          assert_sent_messages_amount(oper.pid, 4)
        end)
      end
    end

    test "does not misreport notification errors as configuration loading failures" do
      expect(System, :load_configurations, fn -> :ok end)
      expect(Isupport, :notify_changes, fn _ -> raise "notification failure" end)

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"], capabilities: ["standard-replies"])

        assert_raise RuntimeError, "notification failure", fn ->
          Rehash.handle(oper, %Message{command: "REHASH", params: []})
        end

        assert_sent_messages_count_containing(oper.pid, ~r/FAIL REHASH CONFIG_BAD/, 0)
      end)
    end
  end

  describe "feature configuration during REHASH" do
    setup do
      config = for key <- [:whox, :monitor, :message_ids], do: {key, Application.get_env(:elixircd, key)}
      on_exit(fn -> Enum.each(config, fn {key, value} -> Application.put_env(:elixircd, key, value) end) end)
      :ok
    end

    for enabled <- [true, false] do
      test "announces ISUPPORT changes when WHOX and MONITOR become #{enabled}" do
        Application.put_env(:elixircd, :whox, enabled: not unquote(enabled))
        Application.put_env(:elixircd, :monitor, enabled: not unquote(enabled), max_targets: 100)

        Memento.transaction!(fn ->
          oper = insert(:user, modes: ["o"])
          client = insert(:user, capabilities: [])
          negotiating = insert(:user, registered: false, capabilities: ["cap-notify"])
          insert(:user_monitor, user: client, target_nick_key: "target")

          stub(System, :load_configurations, fn ->
            Application.put_env(:elixircd, :whox, enabled: unquote(enabled))
            Application.put_env(:elixircd, :monitor, enabled: unquote(enabled), max_targets: 100)
          end)

          assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})
          tokens = if unquote(enabled), do: "WHOX MONITOR=100", else: "-WHOX -MONITOR"

          assert_sent_message_contains(
            client.pid,
            ":irc.test 005 #{client.nick} #{tokens} :are supported by this server\r\n"
          )

          assert_sent_messages_amount(client.pid, 1)
          assert_sent_messages_amount(negotiating.pid, 0)
          expected_count = if unquote(enabled), do: 1, else: 0
          assert UserMonitors.count_by_user_pid(client.pid) == expected_count
        end)
      end
    end

    for limit <- [25, 0] do
      test "announces a MONITOR limit of #{limit} without clearing subscriptions" do
        Application.put_env(:elixircd, :monitor, enabled: true, max_targets: 100)

        Memento.transaction!(fn ->
          oper = insert(:user, modes: ["o"])
          client = insert(:user)
          insert(:user_monitor, user: client, target_nick_key: "target")

          stub(System, :load_configurations, fn ->
            Application.put_env(:elixircd, :monitor, enabled: true, max_targets: unquote(limit))
          end)

          assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})
          token = if unquote(limit) == 0, do: "MONITOR", else: "MONITOR=#{unquote(limit)}"

          assert_sent_message_contains(
            client.pid,
            ":irc.test 005 #{client.nick} #{token} :are supported by this server\r\n"
          )

          assert_sent_messages_amount(client.pid, 1)
          assert UserMonitors.count_by_user_pid(client.pid) == 1
        end)
      end
    end

    test "changing message IDs does not announce a capability change" do
      Application.put_env(:elixircd, :message_ids, enabled: true)

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])
        client = insert(:user, capabilities: ["message-tags", "cap-notify"])
        stub(System, :load_configurations, fn -> Application.put_env(:elixircd, :message_ids, enabled: false) end)

        assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})
        assert_sent_messages_amount(client.pid, 0)
        updated = Memento.Query.read(ElixIRCd.Tables.User, client.pid)
        assert updated.capabilities == client.capabilities
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

    for enabled <- [true, false] do
      test "REHASH changes userhost-in-names availability to #{enabled}", %{original_config: original_config} do
        Application.put_env(
          :elixircd,
          :capabilities,
          Keyword.put(original_config, :extended_names, not unquote(enabled))
        )

        Memento.transaction!(fn ->
          oper = insert(:user, modes: ["o"])
          capabilities = if unquote(enabled), do: ["cap-notify"], else: ["cap-notify", "userhost-in-names"]
          client = insert(:user, capabilities: capabilities)
          silent_client = insert(:user, capabilities: ["userhost-in-names"])

          stub(System, :load_configurations, fn ->
            Application.put_env(
              :elixircd,
              :capabilities,
              Keyword.put(original_config, :extended_names, unquote(enabled))
            )
          end)

          assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})
          operation = if unquote(enabled), do: "NEW", else: "DEL"
          assert_sent_message_contains(client.pid, ":irc.test CAP #{client.nick} #{operation} :userhost-in-names\r\n")
          assert_sent_messages_amount(silent_client.pid, 0)
          updated = Memento.Query.read(ElixIRCd.Tables.User, client.pid)
          assert "userhost-in-names" not in updated.capabilities

          unless unquote(enabled) do
            updated_silent = Memento.Query.read(ElixIRCd.Tables.User, silent_client.pid)
            assert "userhost-in-names" not in updated_silent.capabilities
          end
        end)
      end
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
        (original_config || []) |> Keyword.put(:server_time, true)
      )

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])
        client = insert(:user, capabilities: ["cap-notify", "server-time"], registered: true)

        System
        |> stub(:load_configurations, fn ->
          Application.put_env(
            :elixircd,
            :capabilities,
            Application.get_env(:elixircd, :capabilities, [])
            |> Keyword.put(:server_time, false)
          )
        end)

        assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})

        assert_sent_message_contains(client.pid, ~r/CAP .* DEL :.*server-time/)

        updated_client = Memento.Query.read(ElixIRCd.Tables.User, client.pid)
        assert "server-time" not in updated_client.capabilities
        assert "cap-notify" in updated_client.capabilities
      end)
    end

    test "notifies plaintext clients with port when sts availability changes", %{original_config: original_config} do
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(:elixircd, :capabilities, Keyword.delete(original_config || [], :sts))

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])
        client = insert(:user, capabilities: ["cap-notify"], cap_version: 302, registered: true, transport: :tcp)

        System
        |> stub(:load_configurations, fn ->
          Application.put_env(
            :elixircd,
            :capabilities,
            Application.get_env(:elixircd, :capabilities, []) |> Keyword.put(:sts, true)
          )
        end)

        assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})

        assert_sent_message_contains(client.pid, ~r/CAP .* NEW :sts=port=6697/)
      end)
    end

    test "notifies TLS clients with duration when sts availability changes", %{original_config: original_config} do
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(:elixircd, :capabilities, Keyword.delete(original_config || [], :sts))

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])
        client = insert(:user, capabilities: ["cap-notify"], cap_version: 302, registered: true, transport: :tls)

        System
        |> stub(:load_configurations, fn ->
          Application.put_env(
            :elixircd,
            :capabilities,
            Application.get_env(:elixircd, :capabilities, []) |> Keyword.put(:sts, true)
          )
        end)

        assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})

        assert_sent_message_contains(client.pid, ~r/CAP .* NEW :sts=duration=2592000/)
      end)
    end

    test "does not send CAP DEL when sts is disabled", %{original_config: original_config} do
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sts, true)
      )

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])
        client = insert(:user, capabilities: ["cap-notify"], registered: true)

        System
        |> stub(:load_configurations, fn ->
          Application.put_env(
            :elixircd,
            :capabilities,
            Application.get_env(:elixircd, :capabilities, []) |> Keyword.delete(:sts)
          )
        end)

        assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})

        assert_sent_messages_count_containing(client.pid, ~r/CAP .* DEL/, 0)
      end)
    end

    test "announces and removes batch and labeled-response together", %{original_config: original_config} do
      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || [])
        |> Keyword.put(:batch, true)
        |> Keyword.put(:labeled_response, true)
      )

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])

        client =
          insert(:user,
            capabilities: ["cap-notify", "batch", "labeled-response"],
            registered: true
          )

        System
        |> stub(:load_configurations, fn ->
          Application.put_env(
            :elixircd,
            :capabilities,
            Application.get_env(:elixircd, :capabilities, [])
            |> Keyword.put(:batch, false)
            |> Keyword.put(:labeled_response, true)
          )
        end)

        assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})

        assert_sent_message_contains(client.pid, ~r/CAP .* DEL :.*batch/)
        assert_sent_message_contains(client.pid, ~r/CAP .* DEL :.*labeled-response/)

        updated_client = Memento.Query.read(ElixIRCd.Tables.User, client.pid)
        refute "batch" in updated_client.capabilities
        refute "labeled-response" in updated_client.capabilities
        assert "cap-notify" in updated_client.capabilities
      end)
    end

    test "announces standard-replies with NEW without automatically negotiating support", %{
      original_config: original_config
    } do
      Application.put_env(:elixircd, :capabilities, Keyword.put(original_config, :standard_replies, false))

      expect(System, :load_configurations, fn ->
        Application.put_env(:elixircd, :capabilities, Keyword.put(original_config, :standard_replies, true))
      end)

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"], capabilities: ["cap-notify"])
        Rehash.handle(oper, %Message{command: "REHASH", params: []})
        assert_sent_message_contains(oper.pid, ":irc.test CAP #{oper.nick} NEW :standard-replies\r\n")
        assert {:ok, updated} = Users.get_by_pid(oper.pid)
        refute "standard-replies" in updated.capabilities
      end)
    end

    test "finishes the labeled NOTE before standard-replies DEL and restores legacy replies", %{
      original_config: original_config
    } do
      Application.put_env(:elixircd, :capabilities, Keyword.put(original_config, :standard_replies, true))

      expect(System, :load_configurations, fn ->
        Application.put_env(:elixircd, :capabilities, Keyword.put(original_config, :standard_replies, false))
      end)

      Memento.transaction!(fn ->
        oper =
          insert(:user, modes: ["o"], capabilities: ["standard-replies", "cap-notify", "batch", "labeled-response"])

        legacy = insert(:user, capabilities: ["standard-replies"])
        request = %Message{command: "REHASH", params: [], tags: %{"label" => "rehash"}}
        ElixIRCd.Command.dispatch(oper, request)
        assert_sent_message_contains(oper.pid, ~r/^@label=rehash :irc.test BATCH \+/)
        assert_sent_message_contains(oper.pid, ~r/ NOTE REHASH REHASH_COMPLETE :Rehashing completed\r\n$/)
        assert_sent_message_contains(oper.pid, ":irc.test CAP #{oper.nick} DEL :standard-replies\r\n")

        wires =
          Agent.get(@agent_name, fn msgs ->
            msgs |> Enum.reverse() |> Enum.filter(&(elem(&1, 0) == oper.pid)) |> Enum.map(&elem(&1, 1))
          end)

        assert Enum.find_index(wires, &String.contains?(&1, " BATCH -")) <
                 Enum.find_index(wires, &String.contains?(&1, " DEL "))

        {:ok, oper} = Users.get_by_pid(oper.pid)
        {:ok, legacy} = Users.get_by_pid(legacy.pid)
        refute "standard-replies" in oper.capabilities
        refute "standard-replies" in legacy.capabilities
        assert_sent_messages_amount(legacy.pid, 0)
        expect(System, :load_configurations, fn -> :ok end)
        Rehash.handle(oper, %Message{command: "REHASH", params: []})
        assert_sent_message_contains(oper.pid, ":irc.test NOTICE #{oper.nick} :Rehashing completed\r\n")
      end)
    end

    test "withdraws account-notify explicitly and preserves legacy negotiated sessions", %{
      original_config: original_config
    } do
      Application.put_env(:elixircd, :capabilities, Keyword.put(original_config, :account_notify, true))

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])
        subject = insert(:user)
        modern = insert(:user, cap_version: 302, capabilities: ["cap-notify", "account-notify"])
        notified = insert(:user, capabilities: ["cap-notify", "account-notify"])
        legacy = insert(:user, capabilities: ["account-notify"])
        channel = insert(:channel)
        for user <- [subject, modern, notified, legacy], do: insert(:user_channel, user: user, channel: channel)

        stub(System, :load_configurations, fn ->
          Application.put_env(:elixircd, :capabilities, Keyword.put(original_config, :account_notify, false))
        end)

        Rehash.handle(oper, %Message{command: "REHASH", params: []})

        for user <- [modern, notified] do
          assert_sent_message_contains(user.pid, ":irc.test CAP #{user.nick} DEL :account-notify\r\n")
          {:ok, updated} = Users.get_by_pid(user.pid)
          refute "account-notify" in updated.capabilities
        end

        {:ok, updated} = Users.get_by_pid(legacy.pid)
        assert "account-notify" in updated.capabilities
        assert_sent_messages_amount(legacy.pid, 0)
        Nickserv.notify_account_change(subject, "Account")
        Nickserv.notify_account_logout(subject)
        assert_sent_messages_count_containing(legacy.pid, ~r/ ACCOUNT /, 2)
        for user <- [modern, notified], do: assert_sent_messages_count_containing(user.pid, ~r/ ACCOUNT /, 0)
      end)
    end

    test "REHASH cannot withdraw implicit CAP 302 notifications", %{original_config: original_config} do
      Application.put_env(:elixircd, :capabilities, Keyword.put(original_config, :cap_notify, true))

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])
        modern = insert(:user, capabilities: ["cap-notify"], cap_version: 302)
        legacy = insert(:user, capabilities: ["cap-notify"])

        stub(System, :load_configurations, fn ->
          Application.put_env(:elixircd, :capabilities, Keyword.put(original_config, :cap_notify, false))
        end)

        Rehash.handle(oper, %Message{command: "REHASH", params: []})
        assert_sent_messages_amount(modern.pid, 0)
        assert_sent_message_contains(legacy.pid, ":irc.test CAP #{legacy.nick} DEL :cap-notify\r\n")
        {:ok, updated} = Users.get_by_pid(modern.pid)
        assert "cap-notify" in updated.capabilities
      end)
    end
  end

  describe "STS policy updates" do
    setup do
      caps = Application.get_env(:elixircd, :capabilities)
      sts = Application.get_env(:elixircd, :sts)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, caps)
        Application.put_env(:elixircd, :sts, sts)
      end)

      Application.put_env(:elixircd, :capabilities, Keyword.put(caps, :sts, true))
      Application.put_env(:elixircd, :sts, port: 6697, duration: 3600, preload: false)
    end

    for {key, value, tcp_reply, tls_reply} <- [
          {:duration, 7200, nil, "sts=duration=7200"},
          {:duration, 0, nil, "sts=duration=0"},
          {:preload, true, nil, "sts=duration=3600,preload"},
          {:port, 7000, "sts=port=7000", nil},
          {:duration, 3600, nil, nil}
        ] do
      test "announces effective per-transport changes for #{key}=#{value}" do
        Memento.transaction!(fn ->
          oper = insert(:user, modes: ["o"])
          legacy = insert(:user, capabilities: [], transport: :tls)

          clients =
            for transport <- [:tcp, :ws, :tls, :wss],
                do: insert(:user, transport: transport, capabilities: ["cap-notify"], cap_version: 302)

          stub(System, :load_configurations, fn ->
            Application.put_env(
              :elixircd,
              :sts,
              Keyword.put(Application.get_env(:elixircd, :sts), unquote(key), unquote(value))
            )
          end)

          assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})
          assert_sent_messages_amount(legacy.pid, 0)

          Enum.each(clients, fn client ->
            expected = if client.transport in [:tls, :wss], do: unquote(tls_reply), else: unquote(tcp_reply)

            if expected do
              assert_sent_message_contains(client.pid, ":irc.test CAP #{client.nick} NEW :#{expected}\r\n")
              assert_sent_messages_amount(client.pid, 1)
            else
              assert_sent_messages_amount(client.pid, 0)
            end
          end)
        end)
      end
    end

    test "disabling STS revokes TLS policies without CAP DEL or plaintext revocation" do
      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])
        plaintext = insert(:user, transport: :tcp, capabilities: ["cap-notify"], cap_version: 302)
        tls = insert(:user, transport: :tls, capabilities: ["cap-notify"], cap_version: 302)
        wss = insert(:user, transport: :wss, capabilities: ["cap-notify"], cap_version: 302)

        stub(System, :load_configurations, fn ->
          Application.put_env(
            :elixircd,
            :capabilities,
            Keyword.put(Application.get_env(:elixircd, :capabilities), :sts, false)
          )
        end)

        assert :ok = Rehash.handle(oper, %Message{command: "REHASH", params: []})
        assert_sent_messages_amount(plaintext.pid, 0)

        for client <- [tls, wss] do
          assert_sent_message_contains(client.pid, ":irc.test CAP #{client.nick} NEW :sts=duration=0\r\n")
          assert_sent_messages_count_containing(client.pid, ~r/ CAP .* DEL /, 0)
          assert_sent_messages_amount(client.pid, 1)
        end
      end)
    end

    test "STS withdrawal requires CAP 302 even with explicitly negotiated cap-notify" do
      caps = Application.get_env(:elixircd, :capabilities)

      Application.put_env(:elixircd, :capabilities, Keyword.put(caps, :sts, true))
      Application.put_env(:elixircd, :sts, duration: 3600, port: 6697)

      Memento.transaction!(fn ->
        oper = insert(:user, modes: ["o"])

        clients =
          for version <- [301, 302, 303],
              do: insert(:user, transport: :tls, capabilities: ["cap-notify"], cap_version: version)

        stub(System, :load_configurations, fn ->
          Application.put_env(:elixircd, :capabilities, Keyword.put(caps, :sts, false))
        end)

        Rehash.handle(oper, %Message{command: "REHASH", params: []})

        for user <- clients do
          assert_sent_messages_count_containing(
            user.pid,
            ~r/ NEW :sts=duration=0/,
            if(user.cap_version >= 302, do: 1, else: 0)
          )

          assert_sent_messages_count_containing(user.pid, ~r/ DEL .*sts/, 0)
        end
      end)
    end
  end
end
