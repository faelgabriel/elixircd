defmodule ElixIRCd.ServerLink.Projector do
  @moduledoc """
  Projects committed local Mnesia user and channel changes into an ordered wire stream.

  Detailed Mnesia table events are delivered after transaction commit. This
  process ignores unregistered users and changes to fields that are absent
  from the public S2S records. A restart creates a new epoch; links must
  restart and receive a fresh snapshot before accepting later events.
  """

  use GenServer

  require Logger

  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.ServerLink.ChannelState
  alias ElixIRCd.ServerLink.Frame
  alias ElixIRCd.ServerLink.Snapshot
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Tables.ChannelExcept
  alias ElixIRCd.Tables.ChannelIdentity
  alias ElixIRCd.Tables.ChannelInvex
  alias ElixIRCd.Tables.ChannelInvite
  alias ElixIRCd.Tables.ChannelKickMarker
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.CaseMapping

  @channel_tables [Channel, UserChannel, ChannelBan, ChannelExcept, ChannelIdentity, ChannelInvex, ChannelInvite]
  @default_subscriber_queue 256
  @default_inbound_queue 4_096

  defmodule LocalUser do
    @moduledoc "The stable UID and current public payload for one local client process."

    alias ElixIRCd.ServerLink.UserPayload

    @enforce_keys [:uid, :payload]
    defstruct [:uid, :payload]

    @type t :: %__MODULE__{uid: String.t(), payload: UserPayload.wire_user()}
  end

  defmodule State do
    @moduledoc "The committed local projection and its monitored consumers."

    alias ElixIRCd.ServerLink.ChannelState
    alias ElixIRCd.ServerLink.Projector.LocalUser
    alias ElixIRCd.ServerLink.Projector.Subscription

    @enforce_keys [:origin, :epoch, :users, :channel_state, :max_inbound_queue]
    defstruct [
      :origin,
      :epoch,
      :users,
      :channel_state,
      :max_inbound_queue,
      cursor: 0,
      refresh_pending: false,
      subscribers: %{}
    ]

    @type t :: %__MODULE__{
            origin: String.t(),
            epoch: String.t(),
            users: %{optional(pid()) => LocalUser.t()},
            channel_state: ChannelState.t(),
            max_inbound_queue: pos_integer(),
            cursor: non_neg_integer(),
            refresh_pending: boolean(),
            subscribers: %{optional(pid()) => Subscription.t()}
          }
  end

  defmodule Subscription do
    @moduledoc "A monitored consumer and its maximum pending projector messages."

    @enforce_keys [:pid, :ref, :max_queue]
    defstruct [:pid, :ref, :max_queue]

    @type t :: %__MODULE__{pid: pid(), ref: reference(), max_queue: pos_integer()}
  end

  defmodule Overflow do
    @moduledoc "Signals that a consumer must resubscribe and rebuild from a fresh snapshot."

    @enforce_keys [:epoch, :sequence]
    defstruct [:epoch, :sequence]

    @type t :: %__MODULE__{epoch: String.t(), sequence: pos_integer()}
  end

  @doc "Starts the local event projector and subscribes to committed user/channel table changes."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    name = Keyword.get(options, :name, __MODULE__)
    start_options = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, options, start_options)
  end

  @doc "Subscribes to ordered events; a full mailbox gets one overflow signal and must resubscribe from a snapshot."
  @spec subscribe(GenServer.server(), pid(), keyword()) :: :ok
  def subscribe(projector, subscriber, options \\ []) do
    max_queue = Keyword.get(options, :max_queue, @default_subscriber_queue)

    if is_integer(max_queue) and max_queue > 0 do
      GenServer.call(projector, {:subscribe, subscriber, max_queue})
    else
      raise ArgumentError, "max_queue must be a positive integer"
    end
  end

  @doc "Returns the projector state at one serial point in its event stream."
  @spec snapshot(GenServer.server()) :: Snapshot.t()
  def snapshot(projector), do: GenServer.call(projector, :snapshot)

  @doc "Refreshes committed channel membership before taking a routing snapshot."
  @spec refresh_snapshot(GenServer.server()) :: ElixIRCd.ServerLink.Snapshot.t()
  def refresh_snapshot(projector), do: GenServer.call(projector, :refresh_snapshot)

  @doc "Returns the network UID for a currently registered local connection."
  @spec uid_for_pid(GenServer.server(), pid()) :: {:ok, String.t()} | :error
  def uid_for_pid(projector, pid), do: GenServer.call(projector, {:uid_for_pid, pid})

  @doc "Returns the local connection PID for a UID owned by this projector."
  @spec pid_for_uid(GenServer.server(), String.t()) :: {:ok, pid()} | :error
  def pid_for_uid(projector, uid), do: GenServer.call(projector, {:pid_for_uid, uid})

  @impl true
  def init(options) do
    origin = Keyword.get(options, :id, Application.fetch_env!(:elixircd, :server)[:hostname])
    epoch = UserPayload.new_uid()
    max_inbound_queue = Keyword.get(options, :max_inbound_queue, @default_inbound_queue)

    if not (is_integer(max_inbound_queue) and max_inbound_queue > 0),
      do: raise(ArgumentError, "max_inbound_queue must be a positive integer")

    {:ok, _node} = :mnesia.subscribe({:table, User, :detailed})
    Enum.each(@channel_tables, fn table -> {:ok, _node} = :mnesia.subscribe({:table, table, :detailed}) end)

    users =
      Memento.transaction!(fn -> Users.get_all() end)
      |> Enum.filter(&(&1.registered and is_pid(&1.pid)))
      |> Map.new(fn user ->
        uid = UserPayload.new_uid()
        {user.pid, %LocalUser{uid: uid, payload: UserPayload.from_local(user, uid)}}
      end)

    channel_state = ChannelState.snapshot(users, origin)
    prune_kick_markers(channel_state, users)

    {:ok,
     %State{
       origin: origin,
       epoch: epoch,
       users: users,
       channel_state: channel_state,
       max_inbound_queue: max_inbound_queue
     }}
  end

  @impl true
  def handle_call({:subscribe, subscriber, max_queue}, _from, state) do
    if Map.has_key?(state.subscribers, subscriber) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(subscriber)
      subscription = %Subscription{pid: subscriber, ref: ref, max_queue: max_queue}
      {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, subscriber, subscription)}}
    end
  end

  def handle_call(:snapshot, _from, state) do
    state = if state.refresh_pending, do: refresh_channels(state), else: state
    state = %{state | refresh_pending: false}
    {:reply, snapshot_state(state), state}
  end

  def handle_call(:refresh_snapshot, _from, state) do
    state = refresh_channels(state)
    state = %{state | refresh_pending: false}
    {:reply, snapshot_state(state), state}
  end

  def handle_call({:uid_for_pid, pid}, _from, state) do
    state = refresh_local_user(state, pid)

    reply = with {:ok, %LocalUser{uid: uid}} <- Map.fetch(state.users, pid), do: {:ok, uid}
    {:reply, reply, state}
  end

  def handle_call({:pid_for_uid, uid}, _from, state) do
    reply =
      Enum.find_value(state.users, :error, fn {pid, entry} ->
        if entry.uid == uid, do: {:ok, pid}
      end)

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:mnesia_table_event, {:write, User, raw, _old, _tid}}, state) do
    state |> refresh_local_user(elem(raw, 1)) |> schedule_channel_refresh() |> after_event()
  end

  def handle_info({:mnesia_table_event, {:delete, User, {User, pid}, _old, _tid}}, state) do
    state |> refresh_local_user(pid) |> schedule_channel_refresh() |> after_event()
  end

  def handle_info({:mnesia_table_event, {operation, table, _record, _old, _tid}}, state)
      when operation in [:write, :delete] and table in @channel_tables do
    state |> schedule_channel_refresh() |> after_event()
  end

  def handle_info(:refresh_channels, %{refresh_pending: true} = state) do
    %{refresh_channels(state) | refresh_pending: false} |> after_event()
  end

  def handle_info(:refresh_channels, state), do: after_event(state)

  def handle_info({:DOWN, ref, :process, subscriber, _reason}, state) do
    subscribers =
      case Map.get(state.subscribers, subscriber) do
        %Subscription{ref: ^ref} -> Map.delete(state.subscribers, subscriber)
        _ -> state.subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  defp project_write(state, %User{pid: pid, registered: true} = user) when is_pid(pid) do
    uid =
      case Map.fetch(state.users, pid) do
        {:ok, existing} -> existing.uid
        :error -> UserPayload.new_uid()
      end

    payload = UserPayload.from_local(user, uid)

    case Map.fetch(state.users, pid) do
      {:ok, %LocalUser{payload: ^payload}} ->
        state

      _ ->
        sequence = state.cursor + 1

        frame = %{
          "type" => "user_upsert",
          "origin" => state.origin,
          "epoch" => state.epoch,
          "sequence" => sequence,
          "user" => payload
        }

        %{state | cursor: sequence, users: Map.put(state.users, pid, %LocalUser{uid: uid, payload: payload})}
        |> notify(frame)
    end
  end

  defp project_write(state, %User{pid: pid}), do: project_remove(state, pid)

  defp project_remove(state, pid) do
    case Map.pop(state.users, pid) do
      {nil, _users} ->
        state

      {%LocalUser{uid: uid}, users} ->
        sequence = state.cursor + 1

        frame = %{
          "type" => "user_remove",
          "origin" => state.origin,
          "epoch" => state.epoch,
          "sequence" => sequence,
          "uid" => uid
        }

        %{state | cursor: sequence, users: users}
        |> notify(frame)
    end
  end

  defp notify(state, frame) do
    subscribers = dispatch(state.subscribers, {:server_link_local_event, frame}, state.epoch, state.cursor)
    %{state | subscribers: subscribers}
  end

  defp dispatch(subscribers, message, epoch, sequence) do
    Enum.reduce(subscribers, %{}, fn {pid, %Subscription{} = subscription}, active ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, count} when count < subscription.max_queue ->
          send(pid, message)
          Map.put(active, pid, subscription)

        {:message_queue_len, _count} ->
          send(pid, {:server_link_projector_overflow, %Overflow{epoch: epoch, sequence: sequence}})
          Process.demonitor(subscription.ref, [:flush])
          active

        nil ->
          Process.demonitor(subscription.ref, [:flush])
          active
      end
    end)
  end

  defp after_event(%State{} = state) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, count} when count > state.max_inbound_queue ->
        Logger.warning("server link projector input queue exceeded #{state.max_inbound_queue}; restarting projection")
        {:stop, :projector_input_overflow, state}

      _ ->
        {:noreply, state}
    end
  end

  defp schedule_channel_refresh(%{refresh_pending: true} = state), do: state

  defp schedule_channel_refresh(state) do
    send(self(), :refresh_channels)
    %{state | refresh_pending: true}
  end

  defp refresh_local_user(state, pid) do
    case Memento.transaction!(fn -> Users.get_by_pid(pid) end) do
      {:ok, %User{registered: true} = user} -> project_write(state, user)
      _ -> project_remove(state, pid)
    end
  end

  defp refresh_channels(state) do
    channel_state = ChannelState.snapshot(state.users, state.origin)
    updated = refresh_changed_channels(state, channel_state)
    prune_kick_markers(channel_state, state.users)
    updated
  end

  defp refresh_changed_channels(state, channel_state) do
    if channel_state == state.channel_state do
      state
    else
      {changes, kick_markers} =
        state.channel_state
        |> ChannelState.diff(channel_state)
        |> annotate_kicks(state.users)

      common = %{"origin" => state.origin, "epoch" => state.epoch}

      {cursor, subscribers} = dispatch_channel_changes(state, changes, common)
      delete_kick_markers(kick_markers)

      %{state | channel_state: channel_state, cursor: cursor, subscribers: subscribers}
    end
  end

  defp prune_kick_markers(channel_state, users) do
    uid_to_pid = Map.new(users, fn {pid, %LocalUser{uid: uid}} -> {uid, pid} end)

    live_keys =
      channel_state.members
      |> Enum.flat_map(&kick_marker_key(&1, uid_to_pid))
      |> MapSet.new()

    Memento.transaction!(fn ->
      ChannelKickMarker
      |> Memento.Query.all()
      |> Enum.each(&prune_kick_marker(&1, live_keys))
    end)
  end

  defp kick_marker_key(member, uid_to_pid) do
    case Map.fetch(uid_to_pid, member["uid"]) do
      {:ok, pid} -> [{CaseMapping.normalize(member["channel"]), pid, member["joined_at"]}]
      :error -> []
    end
  end

  defp prune_kick_marker(marker, live_keys) do
    if not MapSet.member?(live_keys, marker.key) and Memento.Query.read(ChannelKickMarker, marker.key) == marker,
      do: Memento.Query.delete_record(marker)
  end

  defp dispatch_channel_changes(state, changes, common) do
    changes
    |> Enum.chunk_every(Frame.max_delta_entries())
    |> Enum.reduce({state.cursor, state.subscribers}, fn chunk, progress ->
      dispatch_channel_delta(chunk, progress, common, state.epoch)
    end)
  end

  defp delete_kick_markers(markers) do
    Memento.transaction!(fn -> Enum.each(markers, &delete_kick_marker/1) end)
  end

  defp delete_kick_marker(marker) do
    if Memento.Query.read(ChannelKickMarker, marker.key) == marker,
      do: Memento.Query.delete_record(marker)
  end

  defp annotate_kicks(changes, users) do
    uid_to_pid = Map.new(users, fn {pid, %LocalUser{uid: uid}} -> {uid, pid} end)

    Memento.transaction!(fn ->
      Enum.map_reduce(changes, [], fn change, markers ->
        annotate_kick_change(change, markers, uid_to_pid, users)
      end)
    end)
  end

  defp annotate_kick_change(change, markers, uid_to_pid, users) do
    case kick_marker(change, uid_to_pid) do
      %ChannelKickMarker{} = marker ->
        metadata = kick_metadata(marker, users)
        updated = if metadata, do: Map.put(change, "kick", metadata), else: change
        {updated, [marker | markers]}

      nil ->
        {change, markers}
    end
  end

  defp kick_marker(%{"field" => "member", "action" => "remove", "entry" => entry}, uid_to_pid) do
    case Map.fetch(uid_to_pid, entry["uid"]) do
      {:ok, pid} ->
        Memento.Query.read(ChannelKickMarker, {CaseMapping.normalize(entry["channel"]), pid, entry["joined_at"]})

      :error ->
        nil
    end
  end

  defp kick_marker(_change, _uid_to_pid), do: nil

  defp kick_metadata(%ChannelKickMarker{} = marker, users) do
    actor_uid =
      case marker.actor_uid do
        nil -> with {:ok, %LocalUser{uid: uid}} <- Map.fetch(users, marker.actor_pid), do: uid
        uid -> uid
      end

    if is_binary(actor_uid) do
      %{
        "actor_origin" => marker.actor_origin,
        "actor_uid" => actor_uid,
        "actor_mask" => marker.actor_mask,
        "reason" => marker.reason
      }
    end
  end

  defp dispatch_channel_delta(chunk, {cursor, subscribers}, common, epoch) do
    sequence = cursor + 1
    frames = delta_batch(common, chunk, sequence)
    {sequence, dispatch(subscribers, {:server_link_local_delta, frames}, epoch, sequence)}
  end

  defp delta_batch(common, chunk, sequence) do
    [%{"type" => "delta_begin", "sequence" => sequence, "count" => length(chunk)}]
    |> Enum.concat(Enum.map(chunk, &Map.put(&1, "type", "delta_entry")))
    |> Enum.concat([%{"type" => "delta_end", "sequence" => sequence}])
    |> Enum.map(&Map.merge(common, &1))
  end

  defp snapshot_state(state) do
    users = state.users |> Map.values() |> Enum.map(& &1.payload) |> Enum.sort_by(& &1["uid"])

    %Snapshot{
      origin: state.origin,
      epoch: state.epoch,
      cursor: state.cursor,
      users: users,
      channels: state.channel_state.channels,
      members: state.channel_state.members,
      lists: state.channel_state.lists,
      invites: state.channel_state.invites
    }
  end
end
