defmodule ElixIRCd.ServerLink.DirectRoutingTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.History
  alias ElixIRCd.History.RemoteIdentity
  alias ElixIRCd.Repositories.ChatHistory
  alias ElixIRCd.Repositories.UserAcceptRemotes
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.ServerLink.DirectMessage.Outbound
  alias ElixIRCd.ServerLink.DirectMessage.Pending
  alias ElixIRCd.ServerLink.Frame
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.NetworkStats
  alias ElixIRCd.ServerLink.Projector
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.Route
  alias ElixIRCd.ServerLink.UserPayload

  @local "irc.test"
  @remote "east.example"
  @remote_uid String.duplicate("a", 32)

  test "a direct PRIVMSG uses typed pending state and accepts only its recipient home's result" do
    {sender, _projector, uid, state, outbound} = source_fixture()
    assert {:noreply, queued} = Hub.handle_info({:send_direct_ready, outbound, uid}, state)
    assert_receive {:link_frame, %{"type" => "direct_message", "id" => id} = frame}
    assert :ok = Frame.validate(frame)

    assert %Pending{uid: ^uid, authority: @remote, target_nick: "Remote", command: "PRIVMSG", text: "hello"} =
             queued.direct_pending[id]

    result = result_frame(queued, id, uid, "unknown_target")

    assert {:reply, {:error, :unknown_route}, ^queued} =
             Hub.handle_call(
               {:remote_frame, @remote, self(), %{result | "epoch" => UserPayload.new_uid()}},
               self(),
               queued
             )

    assert {:reply, {:error, :invalid_direct_result}, ^queued} =
             Hub.handle_call(
               {:remote_frame, @remote, self(), %{result | "to_uid" => UserPayload.new_uid()}},
               self(),
               queued
             )

    assert {:reply, :ok, answered} = Hub.handle_call({:remote_frame, @remote, self(), result}, self(), queued)
    assert answered.direct_pending == %{}
    assert_sent_message_contains(sender.pid, ~r/401 Sender Remote :No such nick\r\n/)
    assert {:noreply, ^answered} = Hub.handle_info({:direct_request_expired, id}, answered)
    assert {:reply, :ok, ^answered} = Hub.handle_call({:remote_frame, @remote, self(), result}, self(), answered)
  end

  test "a successful result clears pending state without sending an IRC error" do
    {sender, _projector, uid, state, outbound} = source_fixture()
    assert {:noreply, queued} = Hub.handle_info({:send_direct_ready, outbound, uid}, state)
    assert_receive {:link_frame, %{"id" => id}}

    assert {:reply, :ok, answered} =
             Hub.handle_call({:remote_frame, @remote, self(), result_frame(queued, id, uid, "ok")}, self(), queued)

    assert answered.direct_pending == %{}
    assert_sent_messages_amount(sender.pid, 0)
  end

  test "source echoes direct messages only after authenticated acceptance" do
    {sender, _projector, uid, state, outbound} = source_fixture(["echo-message"])
    assert {:noreply, queued} = Hub.handle_info({:send_direct_ready, outbound, uid}, state)
    assert_receive {:link_frame, %{"id" => id}}
    assert_sent_messages_amount(sender.pid, 0)

    assert {:reply, :ok, accepted} =
             Hub.handle_call({:remote_frame, @remote, self(), result_frame(queued, id, uid, "ok")}, self(), queued)

    assert_sent_message_contains(sender.pid, ~r/:Sender!.* PRIVMSG Remote :hello\r\n/)

    notice = %{outbound | command: "NOTICE"}
    assert {:noreply, pending_notice} = Hub.handle_info({:send_direct_ready, notice, uid}, accepted)
    assert_receive {:link_frame, %{"command" => "NOTICE", "id" => notice_id}}
    assert_sent_messages_count_containing(sender.pid, ~r/ NOTICE Remote :hello\r\n/, 0)

    assert {:reply, :ok, completed} =
             Hub.handle_call(
               {:remote_frame, @remote, self(), result_frame(pending_notice, notice_id, uid, "ok")},
               self(),
               pending_notice
             )

    assert completed.direct_pending == %{}
    assert_sent_message_contains(sender.pid, ~r/:Sender!.* NOTICE Remote :hello\r\n/)

    assert {:noreply, blocked_notice} = Hub.handle_info({:send_direct_ready, notice, uid}, completed)
    assert_receive {:link_frame, %{"command" => "NOTICE", "id" => blocked_id}}

    assert {:reply, :ok, rejected} =
             Hub.handle_call(
               {:remote_frame, @remote, self(), result_frame(blocked_notice, blocked_id, uid, "accept_only")},
               self(),
               blocked_notice
             )

    assert rejected.direct_pending == %{}
    assert_sent_messages_count_containing(sender.pid, ~r/ NOTICE Remote :hello\r\n/, 1)
    assert_sent_messages_count_containing(sender.pid, ~r/716 Sender Remote/, 0)

    assert {:noreply, blocked_privmsg} = Hub.handle_info({:send_direct_ready, outbound, uid}, rejected)
    assert_receive {:link_frame, %{"command" => "PRIVMSG", "id" => blocked_privmsg_id}}

    assert {:reply, :ok, _rejected_privmsg} =
             Hub.handle_call(
               {:remote_frame, @remote, self(), result_frame(blocked_privmsg, blocked_privmsg_id, uid, "accept_only")},
               self(),
               blocked_privmsg
             )

    assert_sent_messages_count_containing(sender.pid, ~r/ PRIVMSG Remote :hello\r\n/, 1)
    assert_sent_message_contains(sender.pid, ~r/716 Sender Remote :Your message has been blocked/)
  end

  test "an accepted remote message is stored under its UID instead of a same-named local account" do
    {sender, _projector, uid, state, outbound} = source_fixture(["echo-message", "message-tags", "server-time"])
    Memento.transaction!(fn -> insert(:registered_nick, nickname: "Remote", account_name: "LocalAccount") end)

    assert {:noreply, queued} = Hub.handle_info({:send_direct_ready, outbound, uid}, state)
    assert_receive {:link_frame, %{"id" => id, "sent_at" => sent_at}}

    assert {:reply, :ok, _accepted} =
             Hub.handle_call({:remote_frame, @remote, self(), result_frame(queued, id, uid, "ok")}, self(), queued)

    assert_sent_message_contains(sender.pid, ~r/:Sender!.* PRIVMSG Remote :hello\r\n/)
    assert_sent_message_contains(sender.pid, ~r/msgid=#{id};time=#{Regex.escape(sent_at)} /)

    assert [%{target_type: :direct, recipient_account_key: recipient_identity} = entry] =
             Memento.transaction!(fn -> ChatHistory.all() end)

    remote_identity = %RemoteIdentity{origin: @remote, uid: @remote_uid, nick: "Remote"}
    assert recipient_identity == History.remote_identity_key(remote_identity)
    assert entry.sender_account_key == History.identity_key(sender)
    assert entry.msgid == id
    assert DateTime.to_iso8601(entry.occurred_at) == sent_at
    refute recipient_identity == "account:localaccount"
  end

  test "away from the recipient home is returned only after acceptance" do
    {sender, _projector, uid, state, outbound} = source_fixture()
    assert {:noreply, queued} = Hub.handle_info({:send_direct_ready, outbound, uid}, state)
    assert_receive {:link_frame, %{"id" => id}}
    assert_sent_messages_amount(sender.pid, 0)

    assert {:reply, :ok, _answered} =
             Hub.handle_call(
               {:remote_frame, @remote, self(), result_frame(queued, id, uid, "ok", "Back later")},
               self(),
               queued
             )

    assert_sent_message_contains(sender.pid, ~r/301 Sender Remote :Back later\r\n/)

    assert {:noreply, queued_again} = Hub.handle_info({:send_direct_ready, outbound, uid}, state)
    assert_receive {:link_frame, %{"id" => silent_id}}

    assert {:reply, :ok, _silent} =
             Hub.handle_call(
               {:remote_frame, @remote, self(), result_frame(queued_again, silent_id, uid, "silent")},
               self(),
               queued_again
             )

    assert_sent_messages_count_containing(sender.pid, ~r/301 Sender Remote/, 1)
  end

  test "an authenticated +g rejection returns IRC 716 to the original sender" do
    {sender, _projector, uid, state, outbound} = source_fixture()
    assert {:noreply, queued} = Hub.handle_info({:send_direct_ready, outbound, uid}, state)
    assert_receive {:link_frame, %{"id" => id}}

    assert {:reply, :ok, answered} =
             Hub.handle_call(
               {:remote_frame, @remote, self(), result_frame(queued, id, uid, "accept_only")},
               self(),
               queued
             )

    assert answered.direct_pending == %{}
    assert_sent_message_contains(sender.pid, ~r/716 Sender Remote :Your message has been blocked/)
  end

  test "a pending direct message expires and a lost route rejects it immediately" do
    {sender, _projector, uid, state, outbound} = source_fixture()
    assert {:noreply, queued} = Hub.handle_info({:send_direct_ready, outbound, uid}, state)
    assert_receive {:link_frame, %{"id" => id}}

    assert {:noreply, expired} = Hub.handle_info({:direct_request_expired, id}, queued)
    assert expired.direct_pending == %{}
    assert_sent_message_contains(sender.pid, ~r/437 Sender Remote :User is temporarily unavailable/)

    assert {:noreply, queued_again} = Hub.handle_info({:send_direct_ready, outbound, uid}, state)
    assert_receive {:link_frame, %{"id" => next_id}}
    down = %{"type" => "route_down", "origin" => @remote, "epoch" => state.routes[@remote].epoch}
    assert {:reply, :ok, dropped} = Hub.handle_call({:remote_frame, @remote, self(), down}, self(), queued_again)
    assert dropped.direct_pending == %{}
    assert_sent_messages_count_containing(sender.pid, ~r/437 Sender Remote/, 2)
    assert {:noreply, ^dropped} = Hub.handle_info({:direct_request_expired, next_id}, dropped)
  end

  test "NOTICE stays silent when its pending result expires or its route disappears" do
    {sender, _projector, uid, state, outbound} = source_fixture(["echo-message"])
    notice = %{outbound | command: "NOTICE"}
    assert {:noreply, queued} = Hub.handle_info({:send_direct_ready, notice, uid}, state)
    assert_receive {:link_frame, %{"command" => "NOTICE", "id" => id}}
    assert %Pending{command: "NOTICE"} = queued.direct_pending[id]

    assert {:noreply, expired} = Hub.handle_info({:direct_request_expired, id}, queued)
    assert expired.direct_pending == %{}
    assert_sent_messages_amount(sender.pid, 0)

    assert {:noreply, queued_again} = Hub.handle_info({:send_direct_ready, notice, uid}, state)
    assert_receive {:link_frame, %{"command" => "NOTICE", "id" => next_id}}
    down = %{"type" => "route_down", "origin" => @remote, "epoch" => state.routes[@remote].epoch}
    assert {:reply, :ok, dropped} = Hub.handle_call({:remote_frame, @remote, self(), down}, self(), queued_again)
    assert dropped.direct_pending == %{}
    assert_sent_messages_amount(sender.pid, 0)
    assert {:noreply, ^dropped} = Hub.handle_info({:direct_request_expired, next_id}, dropped)
  end

  test "source reports a missing recipient and NOTICE stays silent" do
    {sender, _projector, uid, state, outbound} = source_fixture()
    missing = %{state | replica: Replica.new()}

    assert {:noreply, ^missing} = Hub.handle_info({:send_direct_ready, outbound, uid}, missing)
    assert_sent_message_contains(sender.pid, ~r/401 Sender Remote :No such nick\r\n/)

    notice = %{outbound | command: "NOTICE"}
    assert {:noreply, ^missing} = Hub.handle_info({:send_direct_ready, notice, uid}, missing)
    assert_sent_messages_count_containing(sender.pid, ~r/401 Sender Remote/, 1)
  end

  test "destination acknowledges a local recipient and reports a removed UID" do
    target =
      Memento.transaction!(fn ->
        insert(:user, nick: "Local", away_message: "Current away", capabilities: ["message-tags", "server-time"])
      end)

    projector = start_supervised!({Projector, [name: nil, id: @local]})
    {:ok, target_uid} = Projector.uid_for_pid(projector, target.pid)
    epoch = UserPayload.new_uid()
    remote = build(:user, nick: "Remote") |> UserPayload.from_local(@remote_uid)
    replica = %Replica{users: %{{@remote, @remote_uid} => remote}}
    state = routing_state(replica, projector, epoch)

    frame = direct_frame(epoch, target_uid, "PRIVMSG")
    assert {:reply, :ok, delivered} = Hub.handle_call({:remote_frame, @remote, self(), frame}, self(), state)

    assert_receive {:link_frame,
                    %{"type" => "direct_result", "code" => "ok", "away" => "Current away", "id" => id} = result}

    assert id == frame["id"]
    assert :ok = Frame.validate(result)
    assert_sent_message_contains(target.pid, ~r/:Remote!.* PRIVMSG Local :hello\r\n/)
    assert_sent_message_contains(target.pid, ~r/msgid=#{frame["id"]};time=#{Regex.escape(frame["sent_at"])} /)

    assert [%{sender_account_key: sender_identity, recipient_account_key: recipient_identity}] =
             Memento.transaction!(fn -> ChatHistory.all() end)

    assert sender_identity ==
             History.remote_identity_key(%RemoteIdentity{origin: @remote, uid: @remote_uid, nick: "Remote"})

    assert recipient_identity == History.identity_key(target)
    assert [%{msgid: msgid, occurred_at: occurred_at}] = Memento.transaction!(fn -> ChatHistory.all() end)
    assert msgid == frame["id"]
    assert DateTime.to_iso8601(occurred_at) == frame["sent_at"]

    missing = %{frame | "to_uid" => UserPayload.new_uid(), "id" => UserPayload.new_uid()}
    assert {:reply, :ok, missing_state} = Hub.handle_call({:remote_frame, @remote, self(), missing}, self(), delivered)
    assert_receive {:link_frame, %{"type" => "direct_result", "code" => "unknown_target", "id" => missing_id}}
    assert missing_id == missing["id"]

    notice = direct_frame(epoch, target_uid, "NOTICE")

    assert {:reply, :ok, _notice_state} =
             Hub.handle_call({:remote_frame, @remote, self(), notice}, self(), missing_state)

    assert_receive {:link_frame, %{"type" => "direct_result", "code" => "ok", "away" => nil}}
  end

  test "recipient home replays the original result without delivering a repeated direct ID" do
    target = Memento.transaction!(fn -> insert(:user, nick: "Local", away_message: "First away") end)
    projector = start_supervised!({Projector, [name: nil, id: @local]})
    {:ok, target_uid} = Projector.uid_for_pid(projector, target.pid)
    epoch = UserPayload.new_uid()
    remote = build(:user, nick: "Remote") |> UserPayload.from_local(@remote_uid)
    state = routing_state(%Replica{users: %{{@remote, @remote_uid} => remote}}, projector, epoch)

    frame = direct_frame(epoch, target_uid, "PRIVMSG")
    assert {:reply, :ok, first} = Hub.handle_call({:remote_frame, @remote, self(), frame}, self(), state)
    assert_receive {:link_frame, %{"type" => "direct_result", "id" => id, "away" => "First away"}}
    assert id == frame["id"]

    Memento.transaction!(fn ->
      {:ok, current} = Users.get_by_pid(target.pid)
      Users.update(current, %{away_message: "Changed away"})
    end)

    duplicate = %{frame | "ttl" => 63}
    assert {:reply, :ok, second} = Hub.handle_call({:remote_frame, @remote, self(), duplicate}, self(), first)
    assert_receive {:link_frame, %{"type" => "direct_result", "id" => ^id, "away" => "First away"}}
    assert_sent_messages_count_containing(target.pid, ~r/ PRIVMSG Local :hello\r\n/, 1)
    assert Memento.transaction!(fn -> ChatHistory.all() |> length() end) == 1

    reused = %{frame | "text" => "different"}

    assert {:reply, {:error, :reused_message_id}, ^second} =
             Hub.handle_call({:remote_frame, @remote, self(), reused}, self(), second)

    notice = direct_frame(epoch, target_uid, "NOTICE")
    assert {:reply, :ok, notice_state} = Hub.handle_call({:remote_frame, @remote, self(), notice}, self(), second)
    assert_receive {:link_frame, %{"type" => "direct_result", "code" => "ok", "id" => notice_id}}

    assert {:reply, :ok, _duplicate_notice_state} =
             Hub.handle_call({:remote_frame, @remote, self(), notice}, self(), notice_state)

    assert_receive {:link_frame, %{"type" => "direct_result", "code" => "ok", "id" => ^notice_id}}

    assert_sent_messages_count_containing(target.pid, ~r/ NOTICE Local :hello\r\n/, 1)
    assert Memento.transaction!(fn -> ChatHistory.all() |> length() end) == 2
  end

  test "authenticated route activity publishes and withdraws network counts" do
    table = NetworkStats.create()
    epoch = UserPayload.new_uid()
    remote = build(:user, nick: "Remote") |> UserPayload.from_local(@remote_uid)

    state =
      routing_state(%Replica{users: %{{@remote, @remote_uid} => remote}}, nil, epoch)
      |> Map.put(:indexes, %Hub.Indexes{network_stats: table})

    frame = %{"type" => "route_up", "origin" => @remote, "epoch" => epoch, "path" => [@remote]}
    assert {:reply, :ok, updated} = Hub.handle_call({:remote_frame, @remote, self(), frame}, self(), state)
    assert {:ok, %NetworkStats{remote_visible: 1, remote_servers: 1, direct_servers: 1}} = NetworkStats.get()

    down = %{"type" => "route_down", "origin" => @remote, "epoch" => epoch}
    assert {:reply, :ok, _dropped} = Hub.handle_call({:remote_frame, @remote, self(), down}, self(), updated)
    assert {:ok, %NetworkStats{remote_visible: 0, remote_servers: 0}} = NetworkStats.get()
  end

  test "recipient registration policy reports a precise authenticated result" do
    target = Memento.transaction!(fn -> insert(:user, nick: "Local", modes: [:R]) end)
    projector = start_supervised!({Projector, [name: nil, id: @local]})
    {:ok, target_uid} = Projector.uid_for_pid(projector, target.pid)
    epoch = UserPayload.new_uid()
    remote = build(:user, nick: "Remote") |> UserPayload.from_local(@remote_uid)
    state = routing_state(%Replica{users: %{{@remote, @remote_uid} => remote}}, projector, epoch)

    assert {:reply, :ok, _updated} =
             Hub.handle_call(
               {:remote_frame, @remote, self(), direct_frame(epoch, target_uid, "PRIVMSG")},
               self(),
               state
             )

    assert_receive {:link_frame, %{"type" => "direct_result", "code" => "registered_only"}}
    assert_sent_messages_amount(target.pid, 0)
  end

  test "recipient home enforces remote ACCEPT by authenticated UID" do
    target = Memento.transaction!(fn -> insert(:user, nick: "Local", modes: [:g]) end)
    projector = start_supervised!({Projector, [name: nil, id: @local]})
    {:ok, target_uid} = Projector.uid_for_pid(projector, target.pid)
    epoch = UserPayload.new_uid()
    remote = build(:user, nick: "Remote") |> UserPayload.from_local(@remote_uid)
    state = routing_state(%Replica{users: %{{@remote, @remote_uid} => remote}}, projector, epoch)

    blocked = direct_frame(epoch, target_uid, "PRIVMSG")
    assert {:reply, :ok, blocked_state} = Hub.handle_call({:remote_frame, @remote, self(), blocked}, self(), state)
    assert_receive {:link_frame, %{"type" => "direct_result", "code" => "accept_only"}}
    assert_sent_messages_amount(target.pid, 0)

    blocked_notice = direct_frame(epoch, target_uid, "NOTICE")

    assert {:reply, :ok, blocked_notice_state} =
             Hub.handle_call({:remote_frame, @remote, self(), blocked_notice}, self(), blocked_state)

    assert_receive {:link_frame, %{"type" => "direct_result", "code" => "accept_only"}}
    assert_sent_messages_amount(target.pid, 0)

    Memento.transaction!(fn -> UserAcceptRemotes.create(target.pid, {@remote, @remote_uid}) end)
    allowed = direct_frame(epoch, target_uid, "PRIVMSG")

    assert {:reply, :ok, allowed_state} =
             Hub.handle_call({:remote_frame, @remote, self(), allowed}, self(), blocked_notice_state)

    assert_receive {:link_frame, %{"type" => "direct_result", "code" => "ok"}}
    assert_sent_message_contains(target.pid, ~r/:Remote!.* PRIVMSG Local :hello\r\n/)

    allowed_notice = direct_frame(epoch, target_uid, "NOTICE")

    assert {:reply, :ok, _allowed_notice_state} =
             Hub.handle_call({:remote_frame, @remote, self(), allowed_notice}, self(), allowed_state)

    assert_receive {:link_frame, %{"type" => "direct_result", "code" => "ok", "away" => nil}}
    assert_sent_message_contains(target.pid, ~r/:Remote!.* NOTICE Local :hello\r\n/)
  end

  test "a relay forwards an authenticated direct result toward its source" do
    epoch = UserPayload.new_uid()
    source_epoch = UserPayload.new_uid()

    state =
      routing_state(Replica.new(), nil, epoch)
      |> Map.put(:id, "middle.example")
      |> Map.put(:links, %{@remote => self(), "west.example" => self()})
      |> Map.put(:routes, %{
        @remote => %Route{via: @remote, epoch: epoch, path: [@remote, "middle.example"]},
        "west.example" => %Route{via: "west.example", epoch: source_epoch, path: ["west.example", "middle.example"]}
      })

    frame = %{
      "type" => "direct_result",
      "origin" => @remote,
      "epoch" => epoch,
      "to_origin" => "west.example",
      "to_uid" => UserPayload.new_uid(),
      "id" => UserPayload.new_uid(),
      "code" => "ok",
      "away" => nil,
      "ttl" => 64
    }

    assert {:reply, :ok, ^state} = Hub.handle_call({:remote_frame, @remote, self(), frame}, self(), state)
    assert_receive {:link_frame, %{"type" => "direct_result", "ttl" => 63, "id" => id}}
    assert id == frame["id"]
  end

  defp source_fixture(capabilities \\ []) do
    sender = Memento.transaction!(fn -> insert(:user, nick: "Sender", capabilities: capabilities) end)
    projector = start_supervised!({Projector, [name: nil, id: @local]})
    {:ok, uid} = Projector.uid_for_pid(projector, sender.pid)
    epoch = UserPayload.new_uid()
    remote = build(:user, nick: "Remote") |> UserPayload.from_local(@remote_uid)
    replica = %Replica{users: %{{@remote, @remote_uid} => remote}}
    state = routing_state(replica, projector, epoch)

    outbound = %Outbound{
      sender_pid: sender.pid,
      target_origin: @remote,
      target_uid: @remote_uid,
      target_nick: "Remote",
      command: "PRIVMSG",
      text: "hello",
      tags: %{}
    }

    {sender, projector, uid, state, outbound}
  end

  defp routing_state(replica, projector, epoch) do
    %Hub.State{
      id: @local,
      network: "test-network",
      replays: Hub.ReplayCaches.new(),
      local_epoch: UserPayload.new_uid(),
      local_cursor: 0,
      local_channels: %{},
      replica: replica,
      channel_view: %{},
      channel_authorities: %{},
      indexes: %Hub.Indexes{},
      projector: projector,
      links: %{@remote => self()},
      routes: %{@remote => %Route{via: @remote, epoch: epoch, path: [@remote, @local]}},
      direct_pending: %{},
      topic_pending: %{},
      mode_pending: %{},
      kick_pending: %{}
    }
  end

  defp result_frame(state, id, uid, code, away \\ nil) do
    %{
      "type" => "direct_result",
      "origin" => @remote,
      "epoch" => state.routes[@remote].epoch,
      "to_origin" => @local,
      "to_uid" => uid,
      "id" => id,
      "code" => code,
      "away" => away,
      "ttl" => 64
    }
  end

  defp direct_frame(epoch, target_uid, command) do
    %{
      "type" => "direct_message",
      "origin" => @remote,
      "epoch" => epoch,
      "from_uid" => @remote_uid,
      "to_origin" => @local,
      "to_uid" => target_uid,
      "command" => command,
      "text" => "hello",
      "tags" => %{},
      "ttl" => 64,
      "id" => UserPayload.new_uid(),
      "sent_at" => DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    }
  end
end
