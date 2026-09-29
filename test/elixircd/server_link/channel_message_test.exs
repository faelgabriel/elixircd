defmodule ElixIRCd.ServerLink.ChannelMessageTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Command
  alias ElixIRCd.Commands.Notice
  alias ElixIRCd.Commands.Privmsg
  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.ChannelMessage
  alias ElixIRCd.ServerLink.ChannelMessage.Outbound
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.ChannelView.RemoteRecord
  alias ElixIRCd.ServerLink.Frame
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.ChannelIdentity

  @origin "east.example"
  @epoch String.duplicate("e", 32)
  @uid String.duplicate("a", 32)

  test "a remote channel message reaches local members and respects status targets" do
    {operator, voiced, viewer, channel} = local_channel("#messages")
    {views, sender, _replica} = remote_state(channel, ["o"])

    assert :ok = ChannelMessage.deliver(views, sender, frame(channel, "PRIVMSG", "#messages"))

    assert_sent_messages([
      {operator.pid, ":Remote!~remote@east.example PRIVMSG #messages :hello\r\n"},
      {voiced.pid, ":Remote!~remote@east.example PRIVMSG #messages :hello\r\n"},
      {viewer.pid, ":Remote!~remote@east.example PRIVMSG #messages :hello\r\n"}
    ])

    assert :ok = ChannelMessage.deliver(views, sender, frame(channel, "NOTICE", "@#messages"))
    assert_sent_messages([{operator.pid, ":Remote!~remote@east.example NOTICE @#messages :hello\r\n"}])
    assert_sent_messages_amount(voiced.pid, 0)
    assert_sent_messages_amount(viewer.pid, 0)

    assert :ok = ChannelMessage.deliver(views, sender, frame(channel, "PRIVMSG", "+#messages"))

    assert_sent_messages([
      {operator.pid, ":Remote!~remote@east.example PRIVMSG +#messages :hello\r\n"},
      {voiced.pid, ":Remote!~remote@east.example PRIVMSG +#messages :hello\r\n"}
    ])

    assert_sent_messages_amount(viewer.pid, 0)

    mixed_case = frame(channel, "PRIVMSG", "#MESSAGES")
    assert :ok = Frame.validate(mixed_case)
    assert :ok = ChannelMessage.deliver(views, sender, mixed_case)

    assert_sent_messages([
      {operator.pid, ":Remote!~remote@east.example PRIVMSG #MESSAGES :hello\r\n"},
      {voiced.pid, ":Remote!~remote@east.example PRIVMSG #MESSAGES :hello\r\n"},
      {viewer.pid, ":Remote!~remote@east.example PRIVMSG #MESSAGES :hello\r\n"}
    ])

    mixed_status = frame(channel, "NOTICE", "@#MESSAGES")
    assert :ok = Frame.validate(mixed_status)
    assert :ok = ChannelMessage.deliver(views, sender, mixed_status)
    assert_sent_messages([{operator.pid, ":Remote!~remote@east.example NOTICE @#MESSAGES :hello\r\n"}])
    assert_sent_messages_amount(voiced.pid, 0)
    assert_sent_messages_amount(viewer.pid, 0)
  end

  test "a locally adopted channel accepts its preserved remote creator identity" do
    {operator, voiced, viewer, channel} = local_channel("#adopted-messages")
    Memento.transaction!(fn -> Memento.Query.write(ChannelIdentity.new(channel.name_key, @origin)) end)
    {views, sender, replica} = remote_state(channel, ["o"], [], @origin)
    frame = %{frame(channel, "PRIVMSG", channel.name) | "channel_creator" => @origin}

    assert ChannelMessage.accepted_identity?(views, replica, frame)
    assert :ok = ChannelMessage.deliver(views, sender, frame)

    assert_sent_messages([
      {operator.pid, ":Remote!~remote@east.example PRIVMSG #adopted-messages :hello\r\n"},
      {voiced.pid, ":Remote!~remote@east.example PRIVMSG #adopted-messages :hello\r\n"},
      {viewer.pid, ":Remote!~remote@east.example PRIVMSG #adopted-messages :hello\r\n"}
    ])
  end

  test "selected channel modes block unauthorized remote messages" do
    {operator, voiced, viewer, channel} = local_channel("#restricted")
    {views, sender, _replica} = remote_state(channel, [], ["m", "U"])

    assert :ok = ChannelMessage.deliver(views, sender, frame(channel, "PRIVMSG", channel.name))
    assert_sent_messages_amount(operator.pid, 0)
    assert_sent_messages_amount(voiced.pid, 0)
    assert_sent_messages_amount(viewer.pid, 0)

    {views, sender, _replica} = remote_state(channel, [], ["U"])
    assert :ok = ChannelMessage.deliver(views, sender, frame(channel, "PRIVMSG", channel.name))
    assert_sent_messages([{operator.pid, ":Remote!~remote@east.example PRIVMSG #restricted :hello\r\n"}])
    assert_sent_messages_amount(voiced.pid, 0)
    assert_sent_messages_amount(viewer.pid, 0)

    {views, sender, _replica} = remote_state(channel, [], ["T", "C", "c"])
    assert :ok = ChannelMessage.deliver(views, sender, frame(channel, "NOTICE", channel.name))

    assert :ok =
             ChannelMessage.deliver(views, sender, %{
               frame(channel, "PRIVMSG", channel.name)
               | "text" => "\x01VERSION\x01"
             })

    assert :ok =
             ChannelMessage.deliver(views, sender, %{frame(channel, "PRIVMSG", channel.name) | "text" => "\x02bold"})

    assert_sent_messages_amount(operator.pid, 0)
    assert_sent_messages_amount(voiced.pid, 0)
    assert_sent_messages_amount(viewer.pid, 0)
  end

  test "selected +m blocks local PRIVMSG and NOTICE before echo or network send" do
    enable_links!()
    {operator, _voiced, viewer, channel} = local_channel("#selected-moderated")
    {views, _sender, _replica} = remote_state(channel, [], ["m"])
    table = ChannelDirectory.create()
    ChannelDirectory.sync(table, %{}, views)

    Observability.transaction(fn ->
      assert :ok = Privmsg.handle(viewer, %Message{command: "PRIVMSG", params: [channel.name], trailing: "blocked"})
      assert :ok = Notice.handle(viewer, %Message{command: "NOTICE", params: [channel.name], trailing: "blocked"})
    end)

    assert_sent_message_contains(viewer.pid, ~r/404 Viewer #selected-moderated :Cannot send to channel/)
    assert_sent_messages_amount(viewer.pid, 1)
    assert_sent_messages_amount(operator.pid, 0)
  end

  test "selected modes permit a local message when stale local metadata says +m" do
    enable_links!()
    {operator, voiced, viewer, channel} = local_channel("#selected-open")
    Memento.transaction!(fn -> Channels.update(channel, %{modes: [:m]}) end)
    {views, _sender, _replica} = remote_state(channel, [], [])
    table = ChannelDirectory.create()
    ChannelDirectory.sync(table, %{}, views)
    test_pid = self()

    stub(Hub, :send_channel, fn outbound ->
      send(test_pid, {:queued_channel, outbound})
      :ok
    end)

    Observability.transaction(fn ->
      assert :ok = Privmsg.handle(viewer, %Message{command: "PRIVMSG", params: [channel.name], trailing: "allowed"})
    end)

    assert_received {:queued_channel, %Outbound{} = outbound}

    state = %{
      id: "irc.test",
      local_epoch: @epoch,
      links: %{},
      channel_view: views,
      projector: nil
    }

    assert {:noreply, ^state} = Hub.handle_info({:send_channel_ready, outbound, @uid}, state)

    assert_sent_messages([
      {operator.pid, ":Viewer!~username@hostname PRIVMSG #selected-open :allowed\r\n"},
      {voiced.pid, ":Viewer!~username@hostname PRIVMSG #selected-open :allowed\r\n"}
    ])

    assert_sent_messages_amount(viewer.pid, 0)
  end

  test "a missing network channel view blocks local PRIVMSG and leaves NOTICE silent" do
    enable_links!()
    {operator, _voiced, viewer, channel} = local_channel("#missing-view")

    Observability.transaction(fn ->
      assert :ok = Privmsg.handle(viewer, %Message{command: "PRIVMSG", params: [channel.name], trailing: "blocked"})
      assert :ok = Notice.handle(viewer, %Message{command: "NOTICE", params: [channel.name], trailing: "blocked"})
    end)

    assert_sent_message_contains(viewer.pid, ~r/437 Viewer #missing-view :Channel state is temporarily unavailable/)
    assert_sent_messages_amount(viewer.pid, 1)
    assert_sent_messages_amount(operator.pid, 0)
  end

  test "a remote mute and a local mute use the same effective exception set" do
    enable_links!()
    {operator, voiced, viewer, channel} = local_channel("#combined-mute")
    {views, sender, _replica} = remote_state(channel, [])
    ban = %RemoteRecord{origin: @origin, effective: true, entry: %{"kind" => "b", "mask" => "$m:*!*@*"}}
    exception = %RemoteRecord{origin: @origin, effective: true, entry: %{"kind" => "e", "mask" => "$m:*!*@*"}}
    muted_views = Map.update!(views, channel.name_key, &%{&1 | remote_lists: [ban]})
    table = ChannelDirectory.create()
    ChannelDirectory.sync(table, %{}, muted_views)

    Observability.transaction(fn ->
      assert :ok = Privmsg.handle(viewer, %Message{command: "PRIVMSG", params: [channel.name], trailing: "muted"})
    end)

    assert_sent_message_contains(viewer.pid, ~r/404 Viewer #combined-mute :Cannot send to channel/)
    assert_sent_messages_amount(viewer.pid, 1)
    assert_sent_messages_amount(operator.pid, 0)

    Memento.transaction!(fn -> insert(:channel_ban, channel: channel, mask: "$m:*!*@east.example") end)
    assert :ok = ChannelMessage.deliver(views, sender, frame(channel, "PRIVMSG", channel.name))
    assert_sent_messages_amount(operator.pid, 0)

    excepted_views = Map.update!(views, channel.name_key, &%{&1 | remote_lists: [exception]})
    ChannelDirectory.sync(table, muted_views, excepted_views)

    assert :ok = ChannelMessage.deliver(excepted_views, sender, frame(channel, "PRIVMSG", channel.name))

    assert_sent_messages([
      {operator.pid, ":Remote!~remote@east.example PRIVMSG #combined-mute :hello\r\n"},
      {voiced.pid, ":Remote!~remote@east.example PRIVMSG #combined-mute :hello\r\n"},
      {viewer.pid, ":Remote!~remote@east.example PRIVMSG #combined-mute :hello\r\n"}
    ])
  end

  test "channel message wire rejects wrong target, extra keys, unsafe text and invalid tags" do
    {_operator, _voiced, _viewer, channel} = local_channel("#wire")
    valid = frame(channel, "PRIVMSG", channel.name)
    assert :ok = Frame.validate(valid)
    assert {:ok, _encoded} = Frame.encode(valid)

    for invalid <- [
          %{valid | "target" => "#another"},
          %{valid | "channel" => "other"},
          %{valid | "channel_creator" => "BAD HOST"},
          %{valid | "channel_created_at" => "yesterday"},
          %{valid | "text" => "line\r\nbreak"},
          %{valid | "tags" => %{"account" => "admin"}},
          %{valid | "ttl" => 0},
          Map.put(valid, "pid", "fake")
        ] do
      assert {:error, :invalid_frame} = Frame.validate(invalid)
    end
  end

  test "an effective network mute blocks a remote sender unless excepted" do
    {operator, voiced, viewer, channel} = local_channel("#mute")
    {views, sender, _replica} = remote_state(channel, [])
    ban = %{effective: true, entry: %{"kind" => "b", "mask" => "$m:*!*@east.example"}}
    exception = %{effective: true, entry: %{"kind" => "e", "mask" => "$m:*!*@east.example"}}

    muted_views =
      Map.update!(views, channel.name_key, &%{&1 | remote_lists: [ban]})

    assert :ok = ChannelMessage.deliver(muted_views, sender, frame(channel, "PRIVMSG", channel.name))
    assert_sent_messages_amount(operator.pid, 0)
    assert_sent_messages_amount(voiced.pid, 0)
    assert_sent_messages_amount(viewer.pid, 0)

    excepted_views =
      Map.update!(views, channel.name_key, &%{&1 | remote_lists: [ban, exception]})

    assert :ok = ChannelMessage.deliver(excepted_views, sender, frame(channel, "PRIVMSG", channel.name))

    assert_sent_messages([
      {operator.pid, ":Remote!~remote@east.example PRIVMSG #mute :hello\r\n"},
      {voiced.pid, ":Remote!~remote@east.example PRIVMSG #mute :hello\r\n"},
      {viewer.pid, ":Remote!~remote@east.example PRIVMSG #mute :hello\r\n"}
    ])
  end

  test "the Hub checks origin route, relays once and drops a repeated channel message ID" do
    {operator, voiced, viewer, channel} = local_channel("#relay")
    {views, _sender, replica} = remote_state(channel, ["o"])
    frame = frame(channel, "PRIVMSG", channel.name)

    state = %Hub.State{
      id: "irc.test",
      network: "test-network",
      replays: Hub.ReplayCaches.new(),
      local_epoch: String.duplicate("f", 32),
      links: %{"east.example" => self(), "west.example" => self()},
      routes: %{@origin => %{via: @origin, epoch: @epoch}},
      replica: replica,
      channel_view: views,
      local_channels: %{},
      indexes: %Hub.Indexes{}
    }

    assert {:reply, :ok, updated} =
             Hub.handle_call({:remote_frame, @origin, self(), frame}, {self(), make_ref()}, state)

    assert_receive {:link_frame, %{"type" => "channel_message", "ttl" => 63}}

    assert_sent_messages([
      {operator.pid, ":Remote!~remote@east.example PRIVMSG #relay :hello\r\n"},
      {voiced.pid, ":Remote!~remote@east.example PRIVMSG #relay :hello\r\n"},
      {viewer.pid, ":Remote!~remote@east.example PRIVMSG #relay :hello\r\n"}
    ])

    assert {:reply, :ok, _updated} =
             Hub.handle_call({:remote_frame, @origin, self(), frame}, {self(), make_ref()}, updated)

    refute_receive {:link_frame, _}
    assert_sent_messages_amount(operator.pid, 0)
    assert_sent_messages_amount(voiced.pid, 0)
    assert_sent_messages_amount(viewer.pid, 0)

    stale = %{frame | "epoch" => String.duplicate("f", 32)}

    assert {:reply, {:error, :unknown_sender}, ^updated} =
             Hub.handle_call({:remote_frame, @origin, self(), stale}, {self(), make_ref()}, updated)
  end

  test "a message for another channel incarnation is neither delivered nor relayed" do
    {operator, voiced, viewer, channel} = local_channel("#collision")
    {views, sender, replica} = remote_state(channel, ["o"])
    frame = frame(channel, "PRIVMSG", channel.name)

    state = %Hub.State{
      id: "irc.test",
      network: "test-network",
      replays: Hub.ReplayCaches.new(),
      local_epoch: UserPayload.new_uid(),
      links: %{@origin => self(), "west.example" => self()},
      routes: %{@origin => %{via: @origin, epoch: @epoch}},
      replica: replica,
      channel_view: views,
      indexes: %Hub.Indexes{}
    }

    assert :ok = ChannelMessage.deliver(views, sender, %{frame | "channel_creator" => "other.example"})
    assert_sent_messages_amount(operator.pid, 0)
    assert_sent_messages_amount(voiced.pid, 0)
    assert_sent_messages_amount(viewer.pid, 0)

    other_view =
      Map.update!(views, channel.name_key, fn view ->
        %{view | channel: Map.put(view.channel, "creator", "other.example")}
      end)

    assert :ok =
             ChannelMessage.deliver(other_view, sender, %{frame | "channel_creator" => "other.example"})

    assert_sent_messages_amount(operator.pid, 0)

    stale = %{frame | "channel_creator" => "other.example"}
    assert :ok = Frame.validate(stale)
    assert {:reply, :ok, updated} = Hub.handle_call({:remote_frame, @origin, self(), stale}, self(), state)
    refute_receive {:link_frame, %{"type" => "channel_message"}}
    assert_sent_messages_amount(operator.pid, 0)

    assert {:reply, :ok, ^updated} = Hub.handle_call({:remote_frame, @origin, self(), stale}, self(), updated)

    current = %{frame | "id" => UserPayload.new_uid()}
    assert {:reply, :ok, _} = Hub.handle_call({:remote_frame, @origin, self(), current}, self(), updated)
    assert_receive {:link_frame, %{"type" => "channel_message", "id" => id}}
    assert id == current["id"]
    assert_sent_messages_amount(operator.pid, 1)
  end

  test "the Hub frames a registered local sender only while the channel exists" do
    {operator, voiced, viewer, channel} = local_channel("#outbound")

    operator =
      Memento.transaction!(fn -> Users.update(operator, %{capabilities: ["echo-message"]}) end)

    view = %ChannelView{origin: "irc.test", channel: ChannelPayload.from_local(channel), remote_present: false}

    state = %{
      id: "irc.test",
      local_epoch: @epoch,
      links: %{"east.example" => self()},
      channel_view: %{channel.name_key => view},
      projector: nil
    }

    outbound = %Outbound{
      sender_pid: operator.pid,
      channel: channel.name,
      target: channel.name,
      command: "PRIVMSG",
      text: "hello",
      tags: %{},
      identity: Memento.transaction!(fn -> ChannelMessage.local_identity(channel) end)
    }

    ready = {:send_channel_ready, outbound, @uid}

    assert {:noreply, ^state} = Hub.handle_info(ready, state)

    assert_receive {:link_frame,
                    %{
                      "type" => "channel_message",
                      "origin" => "irc.test",
                      "from_uid" => @uid,
                      "channel" => "#outbound",
                      "text" => "hello"
                    } = outbound_frame}

    assert :ok = Frame.validate(outbound_frame)
    assert_sent_messages_count_containing(voiced.pid, ~r/PRIVMSG #outbound :hello/, 1)
    assert_sent_messages_count_containing(viewer.pid, ~r/PRIVMSG #outbound :hello/, 1)
    assert_sent_messages_count_containing(operator.pid, ~r/PRIVMSG #outbound :hello/, 1)

    stale_view = %{view | channel: Map.put(view.channel, "creator", "other.example")}
    stale_state = %{state | channel_view: %{channel.name_key => stale_view}}
    assert {:noreply, ^stale_state} = Hub.handle_info(ready, stale_state)
    refute_receive {:link_frame, %{"type" => "channel_message"}}
    assert_sent_messages_count_containing(voiced.pid, ~r/PRIVMSG #outbound :hello/, 1)
    assert_sent_messages_count_containing(operator.pid, ~r/PRIVMSG #outbound :hello/, 1)

    missing = {:send_channel_ready, %{outbound | channel: "#missing", target: "#missing"}, @uid}
    assert {:noreply, ^state} = Hub.handle_info(missing, state)
    refute_receive {:link_frame, _}
  end

  test "a newly moderated selected channel rejects queued messages before local echo or wire delivery" do
    enable_links!()
    {operator, voiced, viewer, channel} = local_channel("#late-moderation")

    viewer =
      Memento.transaction!(fn -> Users.update(viewer, %{capabilities: ["echo-message"]}) end)

    open_view = %ChannelView{origin: "irc.test", channel: ChannelPayload.from_local(channel), remote_present: false}
    table = ChannelDirectory.create()
    ChannelDirectory.sync(table, %{}, %{channel.name_key => open_view})
    test_pid = self()

    stub(Hub, :send_channel, fn outbound ->
      send(test_pid, {:queued_channel, outbound})
      :ok
    end)

    Observability.transaction(fn ->
      assert :ok = Privmsg.handle(viewer, %Message{command: "PRIVMSG", params: [channel.name], trailing: "late"})
      assert :ok = Notice.handle(viewer, %Message{command: "NOTICE", params: [channel.name], trailing: "late"})
    end)

    assert_received {:queued_channel, %Outbound{command: "PRIVMSG"} = privmsg}
    assert_received {:queued_channel, %Outbound{command: "NOTICE"} = notice}
    assert_sent_messages_amount(viewer.pid, 0)
    assert_sent_messages_amount(operator.pid, 0)
    assert_sent_messages_amount(voiced.pid, 0)

    moderated = %{open_view | channel: Map.put(open_view.channel, "modes", [%{"name" => "m", "parameter" => nil}])}

    state = %{
      id: "irc.test",
      local_epoch: @epoch,
      links: %{"east.example" => self()},
      channel_view: %{channel.name_key => moderated},
      projector: nil
    }

    assert {:noreply, ^state} = Hub.handle_info({:send_channel_ready, privmsg, @uid}, state)
    assert {:noreply, ^state} = Hub.handle_info({:send_channel_ready, notice, @uid}, state)
    refute_receive {:link_frame, %{"type" => "channel_message"}}
    assert_sent_message_contains(viewer.pid, ~r/404 Viewer #late-moderation :Cannot send to channel/)
    assert_sent_messages_amount(viewer.pid, 1)
    assert_sent_messages_amount(operator.pid, 0)
    assert_sent_messages_amount(voiced.pid, 0)
  end

  test "a local channel send leaves the server only after transaction commit" do
    enable_links!()
    test_pid = self()
    {sender, _voiced, _viewer, channel} = local_channel("#commit")

    stub(Hub, :send_channel, fn outbound ->
      send(test_pid, {:sent_channel, outbound})
      :ok
    end)

    assert_raise RuntimeError, "rollback", fn ->
      Observability.transaction(fn ->
        ChannelMessage.send_from_local(
          sender,
          "#commit",
          "#commit",
          "PRIVMSG",
          "discarded",
          %{"+draft/test" => "yes", "account" => "forged"}
        )

        raise "rollback"
      end)
    end

    refute_received {:sent_channel, _}

    assert :ok =
             Observability.transaction(fn ->
               ChannelMessage.send_from_local(
                 sender,
                 "#commit",
                 "#commit",
                 "PRIVMSG",
                 "accepted",
                 %{"+draft/test" => "yes", "account" => "forged"}
               )
             end)

    assert_received {:sent_channel, %Outbound{} = outbound}
    assert outbound.sender_pid == sender.pid
    assert outbound.channel == channel.name
    assert outbound.target == channel.name
    assert outbound.command == "PRIVMSG"
    assert outbound.text == "accepted"
    assert outbound.tags == %{"+draft/test" => "yes", "account" => "forged"}
  end

  test "linked multiline queues only complete lines and does not duplicate local delivery" do
    enable_links!()
    {operator, _voiced, viewer, channel} = local_channel("#linked-batch")

    viewer =
      Memento.transaction!(fn ->
        Users.update(viewer, %{
          capabilities: ["message-tags", "batch", "draft/multiline", "echo-message"]
        })
      end)

    view = %ChannelView{origin: "irc.test", channel: ChannelPayload.from_local(channel), remote_present: false}
    table = ChannelDirectory.create()
    ChannelDirectory.sync(table, %{}, %{channel.name_key => view})
    test_pid = self()

    stub(Hub, :send_channel, fn outbound ->
      send(test_pid, {:queued_channel, outbound})
      :ok
    end)

    Observability.transaction(fn ->
      assert :ok =
               Command.dispatch(viewer, %Message{command: "BATCH", params: ["+link", "draft/multiline", channel.name]})

      assert :ok =
               Command.dispatch(viewer, %Message{
                 command: "PRIVMSG",
                 params: [channel.name],
                 trailing: "one",
                 tags: %{"batch" => "link"}
               })

      assert :ok =
               Command.dispatch(viewer, %Message{
                 command: "PRIVMSG",
                 params: [channel.name],
                 trailing: "two",
                 tags: %{"batch" => "link"}
               })

      refute_received {:queued_channel, _}
      assert :ok = Command.dispatch(viewer, %Message{command: "BATCH", params: ["-link"]})
    end)

    assert_received {:queued_channel, %Outbound{text: "one", remote_only: true} = first}
    assert_received {:queued_channel, %Outbound{text: "two", remote_only: true} = second}
    refute_received {:queued_channel, _}

    state = %{
      id: "irc.test",
      local_epoch: @epoch,
      links: %{"east.example" => self()},
      channel_view: %{channel.name_key => view},
      projector: nil
    }

    assert {:noreply, ^state} = Hub.handle_info({:send_channel_ready, first, @uid}, state)
    assert {:noreply, ^state} = Hub.handle_info({:send_channel_ready, second, @uid}, state)
    assert_receive {:link_frame, %{"type" => "channel_message", "text" => "one"}}
    assert_receive {:link_frame, %{"type" => "channel_message", "text" => "two"}}
    assert_sent_messages_count_containing(operator.pid, ~r/PRIVMSG #linked-batch :one/, 1)
    assert_sent_messages_count_containing(operator.pid, ~r/PRIVMSG #linked-batch :two/, 1)
    assert_sent_messages_count_containing(viewer.pid, ~r/PRIVMSG #linked-batch :one/, 1)
    assert_sent_messages_count_containing(viewer.pid, ~r/PRIVMSG #linked-batch :two/, 1)
  end

  test "a rejected linked multiline batch never queues its earlier valid line" do
    enable_links!()
    {_operator, _voiced, viewer, channel} = local_channel("#linked-invalid")
    channel = Memento.transaction!(fn -> Channels.update(channel, %{modes: [:c]}) end)

    viewer =
      Memento.transaction!(fn ->
        Users.update(viewer, %{capabilities: ["message-tags", "batch", "draft/multiline"]})
      end)

    view = %ChannelView{origin: "irc.test", channel: ChannelPayload.from_local(channel), remote_present: false}
    table = ChannelDirectory.create()
    ChannelDirectory.sync(table, %{}, %{channel.name_key => view})
    test_pid = self()

    stub(Hub, :send_channel, fn outbound ->
      send(test_pid, {:queued_channel, outbound})
      :ok
    end)

    Observability.transaction(fn ->
      assert :ok =
               Command.dispatch(viewer, %Message{command: "BATCH", params: ["+bad", "draft/multiline", channel.name]})

      assert :ok =
               Command.dispatch(viewer, %Message{
                 command: "PRIVMSG",
                 params: [channel.name],
                 trailing: "valid",
                 tags: %{"batch" => "bad"}
               })

      assert :ok =
               Command.dispatch(viewer, %Message{
                 command: "PRIVMSG",
                 params: [channel.name],
                 trailing: "\x0304invalid",
                 tags: %{"batch" => "bad"}
               })

      assert :ok = Command.dispatch(viewer, %Message{command: "BATCH", params: ["-bad"]})
    end)

    refute_received {:queued_channel, _}
  end

  defp local_channel(name) do
    Memento.transaction!(fn ->
      operator = insert(:user, nick: "Operator")
      voiced = insert(:user, nick: "Voiced")
      viewer = insert(:user, nick: "Viewer")
      channel = insert(:channel, name: name)
      insert(:user_channel, user: operator, channel: channel, modes: [:o])
      insert(:user_channel, user: voiced, channel: channel, modes: [:v])
      insert(:user_channel, user: viewer, channel: channel)
      {operator, voiced, viewer, channel}
    end)
  end

  defp remote_state(channel, status, channel_modes \\ [], creator \\ "irc.test") do
    user = build(:user, nick: "Remote", ident: "~remote", hostname: @origin)
    sender = UserPayload.from_local(user, @uid)
    metadata = ChannelPayload.from_local(channel, creator)
    metadata = %{metadata | "modes" => Enum.map(channel_modes, &%{"name" => &1, "parameter" => nil})}

    member = %{
      "channel" => channel.name,
      "uid" => @uid,
      "modes" => status,
      "joined_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60))
    }

    replica = %{
      Replica.new()
      | users: %{{@origin, @uid} => sender},
        channels: %{{@origin, channel.name_key} => metadata},
        members: %{{@origin, {channel.name_key, @uid}} => member}
    }

    {ChannelView.select("irc.test", %{}, replica), sender, replica}
  end

  defp frame(channel, command, target) do
    %{
      "type" => "channel_message",
      "origin" => @origin,
      "epoch" => @epoch,
      "from_uid" => @uid,
      "channel" => channel.name,
      "channel_creator" => "irc.test",
      "channel_created_at" => DateTime.to_iso8601(channel.created_at),
      "target" => target,
      "command" => command,
      "text" => "hello",
      "tags" => %{},
      "ttl" => 64,
      "id" => String.duplicate("b", 32)
    }
  end

  defp enable_links! do
    prior = Application.fetch_env!(:elixircd, :server_links)
    Application.put_env(:elixircd, :server_links, Keyword.put(prior, :enabled, true))
    on_exit(fn -> Application.put_env(:elixircd, :server_links, prior) end)
  end
end
