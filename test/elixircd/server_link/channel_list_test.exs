defmodule ElixIRCd.ServerLink.ChannelListTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Mode
  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.ChannelList
  alias ElixIRCd.ServerLink.ChannelList.Entry
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.ChannelView.RemoteRecord
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.ModeMutation.Outbound

  @remote "east.example"

  test "MODE lists local and remote entries with one typed network view" do
    {channel, user, _local_ban} =
      Memento.transaction!(fn ->
        channel = Channels.create(%{name: "#shared-list", creator: @remote, created_at: DateTime.utc_now()})
        user = insert(:user, nick: "Viewer")
        insert(:user_channel, user: user, channel: channel)
        local_ban = insert(:channel_ban, channel: channel, mask: "local!*@*", setter: "Local!u@host")
        {channel, user, local_ban}
      end)

    remote_ban = build(:channel_ban, channel_name_key: channel.name_key, mask: "remote!*@*", setter: "Remote!u@host")
    publish(channel, [remote_ban], @remote)

    Memento.transaction!(fn ->
      assert {:ok, [%Entry{}, %Entry{}]} = ChannelList.read(channel, :b)
      assert :ok = Mode.handle(user, %Message{command: "MODE", params: [channel.name, "+b"]})
    end)

    assert_sent_message_contains(user.pid, ~r/367 Viewer #shared-list local!\*@\* Local!u@host/)
    assert_sent_message_contains(user.pid, ~r/367 Viewer #shared-list remote!\*@\* Remote!u@host/)
    assert_sent_messages_count_containing(user.pid, ~r/ 367 /, 2)
  end

  for {kind, factory, numeric} <- [{"e", :channel_except, "348"}, {"I", :channel_invex, "346"}] do
    test "MODE lists remote +#{kind} entries" do
      {channel, user} =
        Memento.transaction!(fn ->
          channel =
            Channels.create(%{name: "#remote-#{unquote(kind)}", creator: @remote, created_at: DateTime.utc_now()})

          user = insert(:user, nick: "Viewer")
          insert(:user_channel, user: user, channel: channel)
          {channel, user}
        end)

      record = build(unquote(factory), channel_name_key: channel.name_key, mask: "remote!*@*", setter: "Remote!u@host")
      publish(channel, [record], @remote, unquote(kind))

      Memento.transaction!(fn ->
        assert {:ok, [%Entry{mask: "remote!*@*"}]} = ChannelList.read(channel, String.to_existing_atom(unquote(kind)))
        assert :ok = Mode.handle(user, %Message{command: "MODE", params: [channel.name, "+#{unquote(kind)}"]})
      end)

      assert_sent_message_contains(user.pid, ~r/ #{unquote(numeric)} Viewer .* remote!\*@\* Remote!u@host /)
    end
  end

  test "a losing local creation cannot leak its list into selected remote metadata" do
    {channel, local_ban} =
      Memento.transaction!(fn ->
        channel = insert(:channel, name: "#collision-list")
        local_ban = insert(:channel_ban, channel: channel, mask: "loser!*@*")
        {channel, local_ban}
      end)

    selected = build(:channel, name: channel.name, created_at: DateTime.add(channel.created_at, -60))
    remote_ban = build(:channel_ban, channel_name_key: channel.name_key, mask: "winner!*@*")
    publish(selected, [remote_ban], @remote)

    Memento.transaction!(fn ->
      assert {:ok, [%Entry{mask: "winner!*@*"}]} = ChannelList.read(channel, :b)
      refute local_ban.mask == remote_ban.mask
    end)
  end

  test "duplicate masks select one deterministic earlier setter" do
    channel =
      Memento.transaction!(fn ->
        channel = Channels.create(%{name: "#duplicate-list", creator: @remote, created_at: DateTime.utc_now()})
        insert(:channel_ban, channel: channel, mask: "same!*@*", setter: "Local!u@host")
        channel
      end)

    remote =
      build(:channel_ban,
        channel_name_key: channel.name_key,
        mask: "same!*@*",
        setter: "Remote!u@host",
        created_at: DateTime.add(channel.created_at, -60)
      )

    publish(channel, [remote], @remote)

    Memento.transaction!(fn ->
      assert {:ok, [%Entry{mask: "same!*@*", setter: "Remote!u@host"}]} = ChannelList.read(channel, :b)
    end)
  end

  test "MODE cannot mutate local metadata while another server is selected" do
    {channel, user} =
      Memento.transaction!(fn ->
        channel = insert(:channel, name: "#remote-mode", modes: [])
        user = insert(:user, nick: "Operator")
        insert(:user_channel, user: user, channel: channel, modes: [:o])
        {channel, user}
      end)

    selected = build(:channel, name: channel.name, created_at: DateTime.add(channel.created_at, -60))
    publish(selected, [], @remote)

    Memento.transaction!(fn ->
      assert :ok = Mode.handle(user, %Message{command: "MODE", params: [channel.name, "+t"]})
      assert {:ok, unchanged} = Channels.get_by_name(channel.name)
      assert unchanged.modes == []
    end)

    assert_sent_message_contains(user.pid, ~r/437 Operator #remote-mode :Channel modes are temporarily unavailable/)
  end

  test "MODE reads selected remote metadata and creation time for a local member" do
    {channel, user} =
      Memento.transaction!(fn ->
        channel = insert(:channel, name: "#remote-mode-read", modes: [:t])
        user = insert(:user, nick: "Viewer")
        insert(:user_channel, user: user, channel: channel)
        {channel, user}
      end)

    selected =
      build(:channel,
        name: channel.name,
        modes: [:n, {:k, "secret"}],
        created_at: DateTime.add(channel.created_at, -60)
      )

    publish(selected, [], @remote)

    Memento.transaction!(fn ->
      assert :ok = Mode.handle(user, %Message{command: "MODE", params: [channel.name]})
      assert {:ok, %{modes: [:t]}} = Channels.get_by_name(channel.name)
    end)

    assert_sent_message_contains(user.pid, ~r/324 Viewer #remote-mode-read \+nk secret\r\n/)

    assert_sent_message_contains(
      user.pid,
      ~r/329 Viewer #remote-mode-read #{DateTime.to_unix(selected.created_at)}\r\n/
    )
  end

  test "MODE queues a typed remote mutation only after commit" do
    {channel, user} =
      Memento.transaction!(fn ->
        channel = insert(:channel, name: "#routed-mode", modes: [])
        user = insert(:user, nick: "Operator")
        insert(:user_channel, user: user, channel: channel, modes: [:o])
        {channel, user}
      end)

    selected = build(:channel, name: channel.name, created_at: DateTime.add(channel.created_at, -60))
    publish(selected, [], @remote)
    true = Process.register(self(), Hub)

    try do
      assert :ok =
               Observability.transaction(fn ->
                 result = Mode.handle(user, %Message{command: "MODE", params: [channel.name, "+t"]})
                 refute_received {:"$gen_cast", _message}
                 result
               end)

      assert_receive {:"$gen_cast", {:request_mode, %Outbound{sender_pid: pid, authority: @remote, mode_string: "+t"}}}
      assert pid == user.pid
      assert {:ok, %{modes: []}} = Memento.transaction!(fn -> Channels.get_by_name(channel.name) end)

      assert_raise RuntimeError, fn ->
        Observability.transaction(fn ->
          Mode.handle(user, %Message{command: "MODE", params: [channel.name, "+n"]})
          raise "rollback"
        end)
      end

      refute_received {:"$gen_cast", {:request_mode, %Outbound{mode_string: "+n"}}}
    after
      Process.unregister(Hub)
    end
  end

  test "MODE sends parsed changes while answering a list query and unknown mode locally" do
    {channel, user} =
      Memento.transaction!(fn ->
        channel = insert(:channel, name: "#mixed-mode", modes: [])
        user = insert(:user, nick: "Operator")
        insert(:user_channel, user: user, channel: channel, modes: [:o])
        {channel, user}
      end)

    selected = build(:channel, name: channel.name, created_at: DateTime.add(channel.created_at, -60))
    publish(selected, [], @remote)
    true = Process.register(self(), Hub)

    try do
      assert :ok =
               Observability.transaction(fn ->
                 Mode.handle(user, %Message{command: "MODE", params: [channel.name, "+bnq"]})
               end)

      assert_receive {:"$gen_cast", {:request_mode, %Outbound{mode_string: "+n", values: []}}}
      assert_sent_message_contains(user.pid, ~r/368 Operator #mixed-mode :End of channel ban list/)
      assert_sent_message_contains(user.pid, ~r/472 Operator q :is unknown mode char to me/)

      assert :ok =
               Observability.transaction(fn ->
                 Mode.handle(user, %Message{command: "MODE", params: [channel.name, "+q"]})
               end)

      refute_received {:"$gen_cast", {:request_mode, _request}}
    after
      Process.unregister(Hub)
    end
  end

  test "missing network directory fails a list query closed when links are enabled" do
    previous = Application.fetch_env!(:elixircd, :server_links)
    on_exit(fn -> Application.put_env(:elixircd, :server_links, previous) end)
    Application.put_env(:elixircd, :server_links, Keyword.put(previous, :enabled, true))

    Memento.transaction!(fn ->
      channel = insert(:channel)
      user = insert(:user, nick: "Viewer")
      insert(:user_channel, user: user, channel: channel)

      assert {:error, :network_directory_unavailable} = ChannelList.read(channel, :b)
      assert :ok = Mode.handle(user, %Message{command: "MODE", params: [channel.name, "+b"]})
      assert :ok = Mode.handle(user, %Message{command: "MODE", params: [channel.name]})
      assert_sent_message_contains(user.pid, ~r/437 Viewer .* :Channel state is temporarily unavailable/)
      assert_sent_messages_count_containing(user.pid, ~r/ 437 /, 2)
    end)
  end

  test "an enabled directory without the channel does not authorize MODE data or writes" do
    previous = Application.fetch_env!(:elixircd, :server_links)
    on_exit(fn -> Application.put_env(:elixircd, :server_links, previous) end)
    Application.put_env(:elixircd, :server_links, Keyword.put(previous, :enabled, true))
    ChannelDirectory.create()

    Memento.transaction!(fn ->
      channel = insert(:channel, name: "#unindexed-mode", modes: [])
      user = insert(:user, nick: "Operator")
      insert(:user_channel, user: user, channel: channel, modes: [:o])

      assert {:error, :network_directory_unavailable} = ChannelList.read(channel, :b)
      assert :ok = Mode.handle(user, %Message{command: "MODE", params: [channel.name, "+t"]})
      assert {:ok, %{modes: []}} = Channels.get_by_name(channel.name)
      assert_sent_message_contains(user.pid, ~r/437 Operator #unindexed-mode :Channel state is temporarily unavailable/)
    end)
  end

  defp publish(channel, remote_records, creator, kind \\ "b") do
    table = ChannelDirectory.create()

    view = %ChannelView{
      origin: creator,
      channel: ChannelPayload.from_local(channel, creator),
      remote_present: true,
      remote_lists:
        Enum.map(remote_records, fn record ->
          %RemoteRecord{
            origin: creator,
            entry: ChannelPayload.list_from_local(record, channel.name, kind),
            effective: true
          }
        end)
    }

    ChannelDirectory.sync(table, %{}, %{channel.name_key => view})
  end
end
