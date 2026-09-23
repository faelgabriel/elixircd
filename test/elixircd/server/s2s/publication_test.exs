defmodule ElixIRCd.Server.S2S.PublicationTest do
  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Server.S2S.Output
  alias ElixIRCd.Server.S2S.Publication

  test "drops pre-registration user and quit publication rows" do
    user = build(:user, registered: false)
    hello = %{"sid" => "root", "boot" => user.home_boot}

    assert {:ok, []} = Publication.rows_for_intent(%{kind: :s2s_user_put, user: user}, hello)

    assert {:ok, []} =
             Publication.rows_for_intent(
               %{kind: :s2s_user_quit, user: user, reason: "connection closed"},
               hello
             )
  end

  test "commits explicit user and channel snapshots without local structs or secrets" do
    user = build(:user, password: "credential-that-must-not-enter-the-outbox", registered: true)
    channel = build(:channel, name: "#snapshot", topic: build(:channel_topic, text: "private topic"))

    assert {:ok, :committed, group} =
             Output.transaction_deferred(fn ->
               assert :ok = Publication.user_changed(user)
               assert :ok = Publication.channel_changed(channel)
               :committed
             end)

    assert [
             %{kind: :s2s_user_put, user: user_snapshot},
             %{kind: :s2s_channel, channel: channel_snapshot}
           ] = group.intents

    refute Map.has_key?(user_snapshot, :__struct__)
    refute Map.has_key?(channel_snapshot, :__struct__)
    refute Map.has_key?(channel_snapshot.topic, :__struct__)
    refute inspect(group) =~ "credential-that-must-not-enter-the-outbox"
    refute inspect(group) =~ inspect(user.pid)

    hello = %{"sid" => "root", "boot" => user.home_boot}
    assert {:ok, user_rows} = Publication.rows_for_intent(List.first(group.intents), hello)
    assert Enum.any?(user_rows, &(&1["kind"] == "user.put"))
    assert {:ok, channel_rows} = Publication.rows_for_intent(List.last(group.intents), hello)
    assert Enum.any?(channel_rows, &(&1["kind"] == "channel.ensure"))

    assert :ok = Output.drain_pending(group, fn _intent -> :ok end)
  end

  test "aborts the transaction when the publication collector is full" do
    user = build(:user, registered: true)

    assert {:error, {:s2s_output_capacity, :output_attempt_bytes}} =
             Output.transaction_deferred(
               fn ->
                 assert :ok = Publication.user_changed(user)
                 :committed
               end,
               max_bytes: 1
             )

    refute Enum.any?(Output.pending_groups(), fn group ->
             Enum.any?(group.intents, &(&1[:kind] == :s2s_user_put))
           end)
  end
end
