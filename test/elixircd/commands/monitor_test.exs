defmodule ElixIRCd.Commands.MonitorTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Monitor

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.UserMonitors
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Monitor, as: MonitorUtils

  describe "handle/2" do
    for config <- [[enabled: false, max_targets: 100], [enabled: false, max_targets: 0]] do
      test "MONITOR disabled with #{inspect(config)} rejects commands and suppresses notifications" do
        original_config = Application.get_env(:elixircd, :monitor)
        on_exit(fn -> Application.put_env(:elixircd, :monitor, original_config) end)
        Application.put_env(:elixircd, :monitor, unquote(config))

        Memento.transaction!(fn ->
          user = insert(:user)
          target = insert(:user, nick: "target")
          insert(:user_monitor, user: user, target_nick_key: "target")

          for params <- [["+", "other"], ["-", "target"], ["C"], ["L"], ["S"], []] do
            assert :ok = Monitor.handle(user, %Message{command: "MONITOR", params: params})
          end

          assert :ok = MonitorUtils.notify_online(target)
          assert :ok = MonitorUtils.notify_offline(target)
          assert UserMonitors.count_by_user_pid(user.pid) == 1
          assert_sent_messages_count_containing(user.pid, ~r/ 421 .* MONITOR :Unknown command/, 6)
          assert_sent_messages_count_containing(user.pid, ~r/ 73[0-4] /, 0)
          assert_sent_messages_amount(user.pid, 6)
        end)
      end
    end

    test "handles MONITOR command with user not registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "MONITOR", params: ["+"]}

        assert :ok = Monitor.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end

    test "handles MONITOR command with not enough parameters" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "MONITOR", params: []}

        assert :ok = Monitor.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} MONITOR :Not enough parameters\r\n"}
        ])
      end)
    end

    test "handles MONITOR + with space separated target" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "MonitorUser")
        target_user = insert(:user, nick: "TargetNick")

        message = %Message{command: "MONITOR", params: ["+", target_user.nick]}
        assert :ok = Monitor.handle(user, message)

        assert_sent_messages_count_containing(user.pid, ~r/730.*TargetNick/, 1)
      end)
    end

    test "handles MONITOR + with online user" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "MonitorUser")
        target_user = insert(:user, nick: "TargetNick")

        message = %Message{command: "MONITOR", params: ["+#{target_user.nick}"]}
        assert :ok = Monitor.handle(user, message)

        assert_sent_messages_count_containing(user.pid, ~r/730.*TargetNick/, 1)
      end)
    end

    test "handles MONITOR + with offline user" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "MonitorUser")

        message = %Message{command: "MONITOR", params: ["+OfflineNick"]}
        assert :ok = Monitor.handle(user, message)

        assert_sent_messages_count_containing(user.pid, ~r/731.*OfflineNick/, 1)
      end)
    end

    test "handles MONITOR + with multiple targets" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "MonitorUser")
        _online_user = insert(:user, nick: "OnlineNick")

        message = %Message{command: "MONITOR", params: ["+OnlineNick,OfflineNick"]}
        assert :ok = Monitor.handle(user, message)

        assert_sent_messages_count_containing(user.pid, ~r/730.*OnlineNick/, 1)
        assert_sent_messages_count_containing(user.pid, ~r/731.*OfflineNick/, 1)
      end)
    end

    test "handles MONITOR + with no targets" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "MONITOR", params: ["+"]}
        assert :ok = Monitor.handle(user, message)
        assert_sent_messages([])
      end)
    end

    test "handles MONITOR - to remove targets" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "MonitorUser")
        target_nick_key = CaseMapping.normalize("TargetNick")

        insert(:user_monitor, user: user, target_nick_key: target_nick_key)

        message = %Message{command: "MONITOR", params: ["-TargetNick"]}
        assert :ok = Monitor.handle(user, message)

        monitors = UserMonitors.get_by_user_pid(user.pid)
        assert Enum.all?(monitors, fn m -> m.target_nick_key != target_nick_key end)
      end)
    end

    test "handles MONITOR - with space separated target" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "MonitorUser")
        target_nick_key = CaseMapping.normalize("TargetNick")
        insert(:user_monitor, user: user, target_nick_key: target_nick_key)

        message = %Message{command: "MONITOR", params: ["-", "TargetNick"]}
        assert :ok = Monitor.handle(user, message)

        refute UserMonitors.exists?(user.pid, "TargetNick")
      end)
    end

    test "handles MONITOR - with no targets" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "MONITOR", params: ["-"]}
        assert :ok = Monitor.handle(user, message)
        assert_sent_messages([])
      end)
    end

    test "handles MONITOR C to clear list" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "MonitorUser")

        insert(:user_monitor, user: user, target_nick_key: "nick1")
        insert(:user_monitor, user: user, target_nick_key: "nick2")

        message = %Message{command: "MONITOR", params: ["C"]}
        assert :ok = Monitor.handle(user, message)

        monitors = UserMonitors.get_by_user_pid(user.pid)
        assert monitors == []
      end)
    end

    test "handles MONITOR L to list targets" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "MonitorUser")

        insert(:user_monitor, user: user, target_nick_key: "nick1")
        insert(:user_monitor, user: user, target_nick_key: "nick2")

        message = %Message{command: "MONITOR", params: ["L"]}
        assert :ok = Monitor.handle(user, message)

        assert_sent_messages_count_containing(user.pid, ~r/732/, 1)
        assert_sent_messages_count_containing(user.pid, ~r/733.*End of MONITOR list/, 1)
      end)
    end

    test "handles MONITOR L with empty list" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "MonitorUser")

        message = %Message{command: "MONITOR", params: ["L"]}
        assert :ok = Monitor.handle(user, message)

        assert_sent_messages_count_containing(user.pid, ~r/733.*End of MONITOR list/, 1)
      end)
    end

    test "handles MONITOR S with empty list" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "MONITOR", params: ["S"]}
        assert :ok = Monitor.handle(user, message)
        assert_sent_messages([])
      end)
    end

    test "handles MONITOR S to get status" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "MonitorUser")
        _online_user = insert(:user, nick: "OnlineNick")
        online_nick_key = CaseMapping.normalize("OnlineNick")
        offline_nick_key = CaseMapping.normalize("OfflineNick")

        insert(:user_monitor, user: user, target_nick_key: online_nick_key)
        insert(:user_monitor, user: user, target_nick_key: offline_nick_key)

        message = %Message{command: "MONITOR", params: ["S"]}
        assert :ok = Monitor.handle(user, message)

        assert_sent_messages_count_containing(user.pid, ~r/730/, 1)
        assert_sent_messages_count_containing(user.pid, ~r/731/, 1)
      end)
    end

    test "handles MONITOR + with duplicate target" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "MonitorUser")
        target_nick_key = CaseMapping.normalize("TargetNick")

        insert(:user_monitor, user: user, target_nick_key: target_nick_key)

        message = %Message{command: "MONITOR", params: ["+TargetNick"]}
        assert :ok = Monitor.handle(user, message)

        assert_sent_messages_count_containing(user.pid, ~r/731.*TargetNick/, 1)

        assert UserMonitors.count_by_user_pid(user.pid) == 1
      end)
    end

    test "handles MONITOR + with unlimited targets" do
      Memento.transaction!(fn ->
        Application.put_env(:elixircd, :monitor, enabled: true, max_targets: 0)
        on_exit(fn -> Application.put_env(:elixircd, :monitor, enabled: true, max_targets: 100) end)

        user = insert(:user, nick: "MonitorUser")

        targets = Enum.map(1..105, fn i -> "target#{i}" end)
        targets_str = Enum.join(targets, ",")

        message = %Message{command: "MONITOR", params: ["+#{targets_str}"]}
        assert :ok = Monitor.handle(user, message)

        assert_sent_messages_count_containing(user.pid, ~r/734/, 0)

        assert UserMonitors.count_by_user_pid(user.pid) == 105
      end)
    end

    test "handles ERR_MONLISTFULL when exceeding limit" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "MonitorUser")

        max_targets = Application.get_env(:elixircd, :monitor, []) |> Keyword.get(:max_targets, 100)

        for i <- 1..max_targets do
          insert(:user_monitor, user: user, target_nick_key: "existing#{i}")
        end

        message = %Message{command: "MONITOR", params: ["+NewNick"]}
        assert :ok = Monitor.handle(user, message)

        assert_sent_messages_count_containing(user.pid, ~r/734.*Monitor list is full/, 1)
      end)
    end

    test "re-adding monitored targets does not consume slots or trigger 734" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "MonitorUser")

        max_targets = Application.get_env(:elixircd, :monitor, []) |> Keyword.get(:max_targets, 100)

        for i <- 1..max_targets do
          insert(:user_monitor, user: user, target_nick_key: "existing#{i}")
        end

        message = %Message{command: "MONITOR", params: ["+existing1,Existing1,existing2"]}
        assert :ok = Monitor.handle(user, message)

        assert_sent_messages_count_containing(user.pid, ~r/734/, 0)
        assert UserMonitors.count_by_user_pid(user.pid) == max_targets
      end)
    end

    test "accepts lowercase list subcommands" do
      Memento.transaction!(fn ->
        user = insert(:user, nick: "MonitorUser")
        insert(:user_monitor, user: user, target_nick_key: "target")

        assert :ok = Monitor.handle(user, %Message{command: "MONITOR", params: ["l"]})

        assert_sent_messages_count_containing(user.pid, ~r/732 .*target/, 1)
        assert_sent_messages_count_containing(user.pid, ~r/733.*End of MONITOR list/, 1)
      end)
    end

    test "handles MONITOR with invalid subcommand" do
      Memento.transaction!(fn ->
        user = insert(:user)
        message = %Message{command: "MONITOR", params: ["INVALID"]}

        assert :ok = Monitor.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 #{user.nick} MONITOR :Not enough parameters\r\n"}
        ])
      end)
    end
  end

  describe "notify_online/1" do
    test "notifies monitoring users when a user comes online" do
      Memento.transaction!(fn ->
        monitoring_user = insert(:user, nick: "MonitorUser")
        target_nick_key = CaseMapping.normalize("NewUser")

        insert(:user_monitor, user: monitoring_user, target_nick_key: target_nick_key)

        online_user = insert(:user, nick: "NewUser")

        MonitorUtils.notify_online(online_user)

        assert_sent_messages_count_containing(monitoring_user.pid, ~r/730.*NewUser/, 1)
      end)
    end
  end

  describe "notify_offline/1" do
    test "notifies monitoring users when a user goes offline" do
      Memento.transaction!(fn ->
        monitoring_user = insert(:user, nick: "MonitorUser")
        target_nick_key = CaseMapping.normalize("LeavingUser")

        insert(:user_monitor, user: monitoring_user, target_nick_key: target_nick_key)

        offline_user = insert(:user, nick: "LeavingUser")

        MonitorUtils.notify_offline(offline_user)

        assert_sent_messages_count_containing(monitoring_user.pid, ~r/731.*LeavingUser/, 1)
      end)
    end
  end
end
