defmodule ElixIRCd.Jobs.HistoryRetentionTest do
  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.History
  alias ElixIRCd.Jobs.HistoryRetention
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChatHistory
  alias ElixIRCd.Repositories.Jobs
  alias ElixIRCd.Repositories.ReadMarkers

  test "schedules recurring cleanup and deletes expired history and abandoned session markers" do
    Memento.transaction!(fn ->
      job = HistoryRetention.schedule()
      assert job.module == HistoryRetention
      assert job.repeat_interval_ms == 3_600_000
      assert Enum.any?(Jobs.get_all(), &(&1.id == job.id))

      old = DateTime.utc_now() |> DateTime.add(-10, :day)

      ChatHistory.create(%{
        id: {"channel:#old", DateTime.to_unix(old, :microsecond), "expired"},
        target_type: :channel,
        target_key: "channel:#old",
        target_name: "#old",
        msgid: "expired",
        message: %Message{command: "PRIVMSG", params: ["#old"], trailing: "old"},
        occurred_at: old
      })

      marker = ReadMarkers.put("session:abandoned", "#old", "#old", old)
      Memento.Query.write(%{marker | updated_at: old})

      active = insert(:user, nick: "Active")
      active_owner = History.identity_key(active)
      active_marker = ReadMarkers.put(active_owner, "#old", "#old", old)
      Memento.Query.write(%{active_marker | updated_at: old})

      assert :ok = HistoryRetention.run(job)
      assert {:error, :history_not_found} = ChatHistory.get_by_msgid("expired")
      assert {:error, :read_marker_not_found} = ReadMarkers.get("session:abandoned", "#old")
      assert {:ok, _} = ReadMarkers.get(active_owner, "#old")
    end)
  end
end
