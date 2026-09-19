defmodule ElixIRCd.Utils.MonitorTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Utils.Monitor

  test "merges shared-channel and extended MONITOR watchers without duplicates" do
    Memento.transaction!(fn ->
      subject = insert(:user, nick: "subject")
      shared = insert(:user, capabilities: ["away-notify"])
      extended = insert(:user, capabilities: ["away-notify", "extended-monitor"])
      both = insert(:user, capabilities: ["away-notify", "extended-monitor"])
      no_event_cap = insert(:user, capabilities: ["extended-monitor"])
      channel = insert(:channel)

      for user <- [subject, shared, both] do
        insert(:user_channel, user: user, channel: channel)
      end

      for watcher <- [extended, both, no_event_cap] do
        insert(:user_monitor, user: watcher, target_nick: subject.nick)
      end

      watchers = Monitor.notification_watchers(subject, "away-notify")

      assert MapSet.new(Enum.map(watchers, & &1.pid)) ==
               MapSet.new([shared.pid, extended.pid, both.pid])
    end)
  end
end
