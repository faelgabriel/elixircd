defmodule ElixIRCd.ServerLink.NickReconcilerTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.NickReconciler
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Utils.CaseMapping

  @origin "east.example"
  @local_id "irc.test"
  @uid String.duplicate("a", 32)
  @epoch String.duplicate("b", 32)

  test "an older remote registration renames the local loser and announces NICK" do
    local = Memento.transaction!(fn -> insert(:user, nick: "Collision") end)
    older = DateTime.add(local.registered_at, -60)
    payload = remote_payload(older)
    replica = committed_user(payload)

    assert :ok = NickReconciler.reconcile(replica, @local_id)

    Memento.transaction!(fn ->
      assert {:ok, renamed} = Users.get_by_pid(local.pid)
      assert renamed.nick != local.nick
      assert String.starts_with?(renamed.nick, "G")
      assert {:ok, ^renamed} = Users.get_by_nick(renamed.nick)
    end)

    assert_sent_message_contains(local.pid, ~r/:Collision!.* NICK G[0-9a-f]+\r\n/)
  end

  test "an older local registration keeps its nickname" do
    local = Memento.transaction!(fn -> insert(:user, nick: "Collision") end)
    payload = remote_payload(DateTime.add(local.registered_at, 60))
    replica = committed_user(payload)

    assert :ok = NickReconciler.reconcile(replica, @local_id)

    Memento.transaction!(fn ->
      assert {:ok, unchanged} = Users.get_by_pid(local.pid)
      assert unchanged.nick == "Collision"
    end)

    assert_sent_messages_amount(local.pid, 0)
  end

  test "the Hub resolves a collision when a remote snapshot commits" do
    local = Memento.transaction!(fn -> insert(:user, nick: "Collision") end)
    payload = remote_payload(DateTime.add(local.registered_at, -60))
    begin_frame = %{"type" => "snapshot_begin", "origin" => @origin, "epoch" => @epoch, "cursor" => 0, "count" => 1}
    item_frame = %{"type" => "snapshot_user", "origin" => @origin, "epoch" => @epoch, "user" => payload}
    end_frame = %{"type" => "snapshot_end", "origin" => @origin, "epoch" => @epoch}
    {:ok, staging} = Replica.apply(Replica.new(), begin_frame)
    {:ok, staging} = Replica.apply(staging, item_frame)

    state = %Hub.State{
      id: @local_id,
      network: "test-network",
      replays: Hub.ReplayCaches.new(),
      local_epoch: UserPayload.new_uid(),
      links: %{@origin => self()},
      routes: %{@origin => %{via: @origin, epoch: @epoch}},
      replica: staging,
      local_channels: %{},
      channel_authorities: %{},
      channel_view: %{},
      indexes: %Hub.Indexes{}
    }

    assert {:reply, :ok, updated} =
             Hub.handle_call({:remote_frame, @origin, self(), end_frame}, {self(), make_ref()}, state)

    assert {:ok, ^payload} = Replica.get_by_uid(updated.replica, @origin, @uid)

    Memento.transaction!(fn ->
      assert {:ok, renamed} = Users.get_by_pid(local.pid)
      assert renamed.nick != "Collision"
    end)
  end

  test "the Hub resolves a later local claim against an older committed remote user" do
    local = Memento.transaction!(fn -> insert(:user, nick: "Collision") end)
    payload = remote_payload(DateTime.add(local.registered_at, -60))

    state = %{
      id: @local_id,
      replica: committed_user(payload),
      links: %{},
      link_cursors: %{},
      local_cursor: 0
    }

    frame = %{
      "type" => "user_upsert",
      "origin" => @local_id,
      "epoch" => @epoch,
      "sequence" => 1,
      "user" => UserPayload.from_local(local, String.duplicate("c", 32))
    }

    assert {:noreply, %{local_cursor: 1}} = Hub.handle_info({:server_link_local_event, frame}, state)

    Memento.transaction!(fn ->
      assert {:ok, renamed} = Users.get_by_pid(local.pid)
      assert renamed.nick != "Collision"
    end)
  end

  defp remote_payload(registered_at) do
    build(:user, nick: "Collision", registered_at: registered_at)
    |> UserPayload.from_local(@uid)
  end

  defp committed_user(payload) do
    identity = {@origin, @uid}

    %Replica{
      users: %{identity => payload},
      nick_keys: %{CaseMapping.normalize(payload["nick"]) => identity}
    }
  end
end
