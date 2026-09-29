defmodule ElixIRCd.ServerLink.Hub do
  @moduledoc """
  Owns the independent TLS listener and the configured direct peer sessions.

  Only the lexically lower server ID initiates each direct link. Both sides
  configure the peer and pin its certificate. This gives one socket per edge
  after simultaneous boots and prevents an unconfigured server from joining.
  """

  use GenServer

  require Logger

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.ChannelAuthority
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.ChannelEvents
  alias ElixIRCd.ServerLink.ChannelMessage
  alias ElixIRCd.ServerLink.ChannelMessage.LocalDelivery, as: ChannelLocalDelivery
  alias ElixIRCd.ServerLink.ChannelMessage.Outbound, as: ChannelOutbound
  alias ElixIRCd.ServerLink.ChannelReconciler
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.DirectMessage
  alias ElixIRCd.ServerLink.DirectMessage.Outbound, as: DirectOutbound
  alias ElixIRCd.ServerLink.DirectMessage.Pending, as: DirectPending
  alias ElixIRCd.ServerLink.Directory
  alias ElixIRCd.ServerLink.DirectReplay
  alias ElixIRCd.ServerLink.DirectReplay.Entry, as: DirectReplayEntry
  alias ElixIRCd.ServerLink.Frame
  alias ElixIRCd.ServerLink.InviteMutation
  alias ElixIRCd.ServerLink.InviteMutation.LocalNotice, as: LocalInviteNotice
  alias ElixIRCd.ServerLink.InviteMutation.Notice, as: InviteNotice
  alias ElixIRCd.ServerLink.InviteMutation.Outbound, as: InviteOutbound
  alias ElixIRCd.ServerLink.InviteMutation.Pending, as: InvitePending
  alias ElixIRCd.ServerLink.InviteReplay
  alias ElixIRCd.ServerLink.InviteReplay.Entry, as: InviteReplayEntry
  alias ElixIRCd.ServerLink.KickMutation
  alias ElixIRCd.ServerLink.KickMutation.Outbound, as: KickOutbound
  alias ElixIRCd.ServerLink.KickMutation.Pending, as: KickPending
  alias ElixIRCd.ServerLink.KickReplay
  alias ElixIRCd.ServerLink.KickReplay.Entry, as: KickReplayEntry
  alias ElixIRCd.ServerLink.MessageReplay
  alias ElixIRCd.ServerLink.ModeMutation
  alias ElixIRCd.ServerLink.ModeMutation.Outbound
  alias ElixIRCd.ServerLink.ModeMutation.Pending, as: ModePending
  alias ElixIRCd.ServerLink.NetworkStats
  alias ElixIRCd.ServerLink.NickReconciler
  alias ElixIRCd.ServerLink.Peer
  alias ElixIRCd.ServerLink.Projector
  alias ElixIRCd.ServerLink.Projector.Overflow
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.Route
  alias ElixIRCd.ServerLink.Snapshot
  alias ElixIRCd.ServerLink.TopicMutation
  alias ElixIRCd.ServerLink.TopicMutation.Pending, as: TopicPending
  alias ElixIRCd.ServerLink.UserEvents
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Utils.CaseMapping
  alias ElixIRCd.Utils.Protocol

  @retry_ms 5_000
  @max_pending_handshakes 32
  @max_outbound_messages 1_024
  @topic_request_timeout_ms 30_000
  @max_pending_topics 1_024
  @mode_request_timeout_ms 30_000
  @max_pending_modes 1_024
  @kick_request_timeout_ms 30_000
  @max_pending_kicks 1_024
  @invite_request_timeout_ms 30_000
  @max_pending_invites 1_024
  @direct_request_timeout_ms 30_000
  @max_pending_directs 1_024
  @max_remote_origins 4_096
  @topology_errors [:topology_cycle, :duplicate_route, :route_changed, :wrong_route_sender]

  defmodule Indexes do
    @moduledoc "Committed read indexes published by the named coordinator."

    defstruct [:directory, :channel_directory, :network_stats]

    @type t :: %__MODULE__{
            directory: :ets.tid() | nil,
            channel_directory: :ets.tid() | nil,
            network_stats: :ets.tid() | nil
          }
  end

  defmodule ReplayCaches do
    @moduledoc "Bounded decisions and message IDs retained by this coordinator."

    alias ElixIRCd.ServerLink.DirectReplay
    alias ElixIRCd.ServerLink.InviteReplay
    alias ElixIRCd.ServerLink.KickReplay
    alias ElixIRCd.ServerLink.MessageReplay

    @enforce_keys [:messages, :direct, :kick, :invite, :invite_notices]
    defstruct [:messages, :direct, :kick, :invite, :invite_notices]

    @type t :: %__MODULE__{
            messages: MessageReplay.t(),
            direct: DirectReplay.t(),
            kick: KickReplay.t(),
            invite: InviteReplay.t(),
            invite_notices: MessageReplay.t()
          }

    @doc "Creates fresh replay windows for one coordinator epoch."
    @spec new() :: t()
    def new do
      %__MODULE__{
        messages: MessageReplay.new(),
        direct: DirectReplay.new(),
        kick: KickReplay.new(),
        invite: InviteReplay.new(),
        invite_notices: MessageReplay.new()
      }
    end
  end

  defmodule State do
    @moduledoc "The authenticated routes, committed replica and bounded mutation work owned by one coordinator."

    alias ElixIRCd.ServerLink.ChannelAuthority
    alias ElixIRCd.ServerLink.ChannelView
    alias ElixIRCd.ServerLink.DirectMessage.Pending, as: DirectPending
    alias ElixIRCd.ServerLink.Hub.Indexes
    alias ElixIRCd.ServerLink.Hub.ReplayCaches
    alias ElixIRCd.ServerLink.InviteMutation.Pending, as: InvitePending
    alias ElixIRCd.ServerLink.KickMutation.Pending, as: KickPending
    alias ElixIRCd.ServerLink.ModeMutation.Pending, as: ModePending
    alias ElixIRCd.ServerLink.Replica
    alias ElixIRCd.ServerLink.Route
    alias ElixIRCd.ServerLink.TopicMutation.Pending, as: TopicPending

    @enforce_keys [
      :id,
      :network,
      :local_epoch,
      :replica,
      :channel_view,
      :indexes,
      :replays
    ]
    defstruct [
      :id,
      :network,
      :listen,
      :listener,
      :acceptor,
      :projector,
      :local_epoch,
      :indexes,
      :replica,
      :channel_view,
      local_cursor: 0,
      local_channels: %{},
      peers: %{},
      channel_authorities: %{},
      replays: nil,
      topic_pending: %{},
      mode_pending: %{},
      kick_pending: %{},
      invite_pending: %{},
      direct_pending: %{},
      routes: %{},
      max_remote_origins: 4_096,
      suppressed: MapSet.new(),
      links: %{},
      link_cursors: %{},
      link_refs: %{},
      pending: %{},
      pending_refs: %{},
      dials: %{},
      dial_refs: %{}
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            network: String.t(),
            listen: keyword() | nil,
            listener: :ssl.sslsocket() | nil,
            acceptor: pid() | nil,
            projector: GenServer.server() | nil,
            local_epoch: String.t(),
            local_cursor: non_neg_integer(),
            local_channels: %{optional(String.t()) => map()},
            indexes: Indexes.t(),
            peers: %{optional(String.t()) => map()},
            channel_authorities: ChannelAuthority.selected(),
            channel_view: %{optional(String.t()) => ChannelView.t()},
            replica: Replica.t(),
            replays: ReplayCaches.t(),
            topic_pending: %{optional(String.t()) => TopicPending.t()},
            mode_pending: %{optional(String.t()) => ModePending.t()},
            kick_pending: %{optional(String.t()) => KickPending.t()},
            invite_pending: %{optional(String.t()) => InvitePending.t()},
            direct_pending: %{optional(String.t()) => DirectPending.t()},
            routes: %{optional(String.t()) => Route.t()},
            max_remote_origins: pos_integer(),
            suppressed: MapSet.t(String.t()),
            links: %{optional(String.t()) => pid()},
            link_cursors: %{optional(String.t()) => non_neg_integer()},
            link_refs: %{optional(reference()) => String.t()},
            pending: %{optional(pid()) => reference()},
            pending_refs: %{optional(reference()) => pid()},
            dials: %{optional(String.t()) => pid()},
            dial_refs: %{optional(reference()) => String.t()}
          }
  end

  @type state :: State.t()

  @doc "Starts the configured direct-link coordinator."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(config) do
    options =
      if config[:name] == nil and Keyword.has_key?(config, :name), do: [], else: [name: config[:name] || __MODULE__]

    GenServer.start_link(__MODULE__, config, options)
  end

  @doc "Returns the configured peer IDs and whether their direct socket is live."
  @spec status(GenServer.server()) :: %{String.t() => :connected | :disconnected}
  def status(hub \\ __MODULE__), do: GenServer.call(hub, :status)

  @doc "Returns the bound TLS listener port, including an ephemeral test port."
  @spec listener_port(GenServer.server()) :: {:ok, :inet.port_number()} | {:error, term()}
  def listener_port(hub \\ __MODULE__), do: GenServer.call(hub, :listener_port)

  @doc "Returns committed remote user records owned by one network origin."
  @spec remote_users(GenServer.server(), String.t()) :: [map()]
  def remote_users(hub, origin), do: GenServer.call(hub, {:remote_users, origin})

  @doc "Returns committed channel metadata contributed by a remote origin."
  @spec remote_channels(GenServer.server(), String.t()) :: [map()]
  def remote_channels(hub, origin), do: GenServer.call(hub, {:remote_channels, origin})

  @doc "Returns committed channel, member, list and invite entries for one remote origin."
  @spec remote_channel_state(GenServer.server(), String.t()) :: map()
  def remote_channel_state(hub, origin), do: GenServer.call(hub, {:remote_channel_state, origin})

  @doc "Returns the current metadata authority selected for one network channel."
  @spec channel_authority(GenServer.server(), String.t()) :: {:ok, ChannelAuthority.winner()} | :error
  def channel_authority(hub, name), do: GenServer.call(hub, {:channel_authority, name})

  @doc "Returns learned server routes, including their authenticated next hop."
  @spec routes(GenServer.server()) :: %{optional(String.t()) => Route.t()}
  def routes(hub \\ __MODULE__), do: GenServer.call(hub, :routes)

  @doc "Returns peers held disconnected after a topology violation."
  @spec suppressed_peers(GenServer.server()) :: [String.t()]
  def suppressed_peers(hub \\ __MODULE__), do: GenServer.call(hub, :suppressed_peers)

  @doc "Queues one local private message for a remote user after the caller's transaction commits."
  @spec send_direct(DirectOutbound.t()) :: :ok | :unavailable
  def send_direct(%DirectOutbound{} = outbound) do
    case Process.whereis(__MODULE__) do
      nil -> :unavailable
      hub -> GenServer.cast(hub, {:send_direct, outbound})
    end
  end

  @doc "Queues one local channel message after the caller's transaction commits."
  @spec send_channel(ChannelOutbound.t()) :: :ok | :unavailable
  def send_channel(%ChannelOutbound{} = outbound) do
    case Process.whereis(__MODULE__) do
      nil -> :unavailable
      hub -> GenServer.cast(hub, {:send_channel, outbound})
    end
  end

  @doc "Queues one authenticated TOPIC mutation for the selected remote channel authority."
  @spec request_topic(pid(), String.t(), String.t(), String.t()) :: :ok | :unavailable
  def request_topic(sender_pid, authority, channel, text) do
    case Process.whereis(__MODULE__) do
      nil -> :unavailable
      hub -> GenServer.cast(hub, {:request_topic, sender_pid, authority, channel, text})
    end
  end

  @doc "Queues one typed metadata MODE request after the client's transaction commits."
  @spec request_mode(Outbound.t()) :: :ok | :unavailable
  def request_mode(%Outbound{} = request) do
    case Process.whereis(__MODULE__) do
      nil -> :unavailable
      hub -> GenServer.cast(hub, {:request_mode, request})
    end
  end

  @doc "Queues one typed KICK request to a remote target's home after the local transaction commits."
  @spec request_kick(KickOutbound.t()) :: :ok | :unavailable
  def request_kick(%KickOutbound{} = request) do
    case Process.whereis(__MODULE__) do
      nil -> :unavailable
      hub -> GenServer.cast(hub, {:request_kick, request})
    end
  end

  @doc "Queues one typed INVITE request to a remote recipient's home after the local transaction commits."
  @spec request_invite(InviteOutbound.t()) :: :ok | :unavailable
  def request_invite(%InviteOutbound{} = request) do
    case Process.whereis(__MODULE__) do
      nil -> :unavailable
      hub -> GenServer.cast(hub, {:request_invite, request})
    end
  end

  @doc "Announces one committed local invitation to members on other servers."
  @spec announce_invite(LocalInviteNotice.t()) :: :ok | :unavailable
  def announce_invite(%LocalInviteNotice{} = request) do
    case Process.whereis(__MODULE__) do
      nil -> :unavailable
      hub -> GenServer.cast(hub, {:announce_invite, request})
    end
  end

  @impl true
  def init(config) do
    server = Application.fetch_env!(:elixircd, :server)
    id = Keyword.get(config, :id, server[:hostname])
    network = Keyword.get(config, :network, server[:name])
    listen = Keyword.fetch!(config, :listen)
    projector = config[:projector]
    peers = Map.new(config[:peers], &{&1.id, &1})
    :ok = :ssl.start()
    {local_epoch, local_cursor, local_channels} = initial_local_state(projector)

    case :ssl.listen(listen[:port], Peer.listen_options(listen)) do
      {:ok, listener} ->
        parent = self()
        acceptor = spawn_link(fn -> accept_loop(listener, parent, id, network) end)

        replica = Replica.new()
        channel_authorities = ChannelAuthority.select(id, local_channels, replica.channels)
        channel_view = ChannelView.build(channel_authorities, replica)

        state = %State{
          id: id,
          network: network,
          listen: listen,
          listener: listener,
          acceptor: acceptor,
          peers: peers,
          projector: projector,
          local_epoch: local_epoch,
          local_cursor: local_cursor,
          local_channels: local_channels,
          indexes: %Indexes{
            directory: if(Keyword.get(config, :name, __MODULE__) == __MODULE__, do: Directory.create(), else: nil),
            channel_directory:
              if(Keyword.get(config, :name, __MODULE__) == __MODULE__, do: ChannelDirectory.create(), else: nil),
            network_stats:
              if(Keyword.get(config, :name, __MODULE__) == __MODULE__, do: NetworkStats.create(), else: nil)
          },
          channel_authorities: channel_authorities,
          channel_view: channel_view,
          replica: replica,
          replays: ReplayCaches.new(),
          topic_pending: %{},
          mode_pending: %{},
          kick_pending: %{},
          invite_pending: %{},
          direct_pending: %{},
          routes: %{},
          max_remote_origins: @max_remote_origins,
          suppressed: MapSet.new(),
          links: %{},
          link_cursors: %{},
          link_refs: %{},
          pending: %{},
          pending_refs: %{},
          dials: %{},
          dial_refs: %{}
        }

        ChannelDirectory.sync(state.indexes.channel_directory, %{}, channel_view)
        NetworkStats.publish(state.indexes.network_stats, replica, state.routes, state.links, channel_view)
        for peer_id <- Map.keys(peers), dialer?(id, peer_id), do: send(self(), {:dial, peer_id})
        {:ok, state}

      {:error, reason} ->
        {:stop, {:server_link_listen_failed, reason}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status =
      Map.new(state.peers, fn {id, _peer} ->
        {id, if(Map.has_key?(state.links, id), do: :connected, else: :disconnected)}
      end)

    {:reply, status, state}
  end

  def handle_call(:listener_port, _from, state) do
    reply = with {:ok, {_address, port}} <- :ssl.sockname(state.listener), do: {:ok, port}
    {:reply, reply, state}
  end

  def handle_call({:remote_users, origin}, _from, state) do
    {:reply, Replica.users_from(state.replica, origin), state}
  end

  def handle_call({:remote_channels, origin}, _from, state) do
    {:reply, Replica.channels_from(state.replica, origin), state}
  end

  def handle_call({:remote_channel_state, origin}, _from, state) do
    reply = %{
      channels: Replica.channels_from(state.replica, origin),
      members: Replica.members_from(state.replica, origin),
      lists: Replica.lists_from(state.replica, origin),
      invites: Replica.invites_from(state.replica, origin)
    }

    {:reply, reply, state}
  end

  def handle_call({:channel_authority, name}, _from, state) do
    {:reply, ChannelAuthority.get(state.channel_authorities, name), state}
  end

  def handle_call(:routes, _from, state), do: {:reply, state.routes, state}
  def handle_call(:suppressed_peers, _from, state), do: {:reply, MapSet.to_list(state.suppressed), state}

  def handle_call({:peer, id}, _from, state) do
    {:reply, Map.fetch(state.peers, id), state}
  end

  def handle_call({:reserve_inbound, pid}, _from, state) do
    if map_size(state.pending) >= @max_pending_handshakes do
      {:reply, {:error, :capacity}, state}
    else
      ref = Process.monitor(pid)

      new_state = %{
        state
        | pending: Map.put(state.pending, pid, ref),
          pending_refs: Map.put(state.pending_refs, ref, pid)
      }

      {:reply, :ok, new_state}
    end
  end

  def handle_call({:register, id, direction, pid}, _from, state) do
    expected_direction = if dialer?(state.id, id), do: :outbound, else: :inbound

    cond do
      not Map.has_key?(state.peers, id) ->
        {:reply, {:error, :unknown_peer}, state}

      direction != expected_direction ->
        {:reply, {:error, :wrong_direction}, state}

      Map.has_key?(state.links, id) ->
        {:reply, {:error, :duplicate_link}, state}

      MapSet.member?(state.suppressed, id) ->
        {:reply, {:error, :topology_suppressed}, state}

      true ->
        snapshot = local_snapshot(state)

        case Snapshot.validate(snapshot, state.replica.max_snapshot_bytes) do
          :ok -> register_snapshot(state, id, pid, snapshot)
          error -> {:reply, error, state}
        end
    end
  end

  def handle_call({:remote_frame, id, pid, frame}, _from, state) do
    reply =
      with true <- state.links[id] == pid,
           :ok <- Frame.validate(frame) do
        maybe_suppress_topology_error(handle_remote_frame(state, id, frame), id)
      else
        false -> {:reply, {:error, :stale_link}, state}
        error -> {:reply, error, state}
      end

    case reply do
      {:reply, :ok, updated} ->
        Directory.sync(state.indexes.directory, state.replica, updated.replica)
        maybe_reconcile_nicks(frame, updated)
        updated = maybe_refresh_channel_views(state, updated)
        maybe_deliver_departures(frame, state, updated)
        UserEvents.deliver(frame, state.replica, updated.replica, state.channel_view)
        prior_memberships = ChannelReconciler.reconcile(state.channel_view, updated.channel_view, state.id)
        maybe_deliver_channel_delta(frame, state, updated, prior_memberships)

        maybe_publish_network_stats(frame, updated)

        {:reply, :ok, updated}

      other ->
        other
    end
  end

  def handle_call({:peer_reject, id, pid, code}, _from, state) do
    if state.links[id] == pid and code in @topology_errors do
      {:reply, :ok, %{state | suppressed: MapSet.put(state.suppressed, id)}}
    else
      {:reply, {:error, :invalid_rejection}, state}
    end
  end

  @impl true
  def handle_cast({:send_direct, %DirectOutbound{} = outbound}, state) do
    if state.projector do
      case Projector.uid_for_pid(state.projector, outbound.sender_pid) do
        {:ok, sender_uid} ->
          send(self(), {:send_direct_ready, outbound, sender_uid})

        :error ->
          DirectMessage.reply(outbound.sender_pid, outbound.target_nick, :unavailable, outbound.command)
      end
    else
      DirectMessage.reply(outbound.sender_pid, outbound.target_nick, :unavailable, outbound.command)
    end

    {:noreply, state}
  end

  def handle_cast({:send_channel, %ChannelOutbound{} = outbound}, state) do
    if state.projector do
      Projector.refresh_snapshot(state.projector)

      case Projector.uid_for_pid(state.projector, outbound.sender_pid) do
        {:ok, sender_uid} ->
          send(self(), {:send_channel_ready, outbound, sender_uid})

        :error ->
          reply_channel_unavailable(outbound)
      end
    else
      reply_channel_unavailable(outbound)
    end

    {:noreply, state}
  end

  def handle_cast({:request_topic, sender_pid, authority, channel, text}, state) do
    if state.projector do
      case Projector.uid_for_pid(state.projector, sender_pid) do
        {:ok, uid} ->
          snapshot = Projector.refresh_snapshot(state.projector)
          send(self(), {:topic_request_ready, sender_pid, uid, authority, channel, text, snapshot.cursor})

        :error ->
          TopicMutation.reply(sender_pid, channel, "unknown_sender")
      end
    else
      TopicMutation.reply(sender_pid, channel, "stale_authority")
    end

    {:noreply, state}
  end

  def handle_cast({:request_mode, %Outbound{} = request}, state) do
    if state.projector do
      case Projector.uid_for_pid(state.projector, request.sender_pid) do
        {:ok, uid} ->
          snapshot = Projector.refresh_snapshot(state.projector)
          send(self(), {:mode_request_ready, request, uid, snapshot.cursor})

        :error ->
          ModeMutation.reply(request.sender_pid, request.channel, "unknown_sender")
      end
    else
      ModeMutation.reply(request.sender_pid, request.channel, "stale_authority")
    end

    {:noreply, state}
  end

  def handle_cast({:request_kick, %KickOutbound{} = request}, state) do
    if state.projector do
      case Projector.uid_for_pid(state.projector, request.sender_pid) do
        {:ok, uid} ->
          snapshot = Projector.refresh_snapshot(state.projector)
          send(self(), {:kick_request_ready, request, uid, snapshot.cursor})

        :error ->
          KickMutation.reply(request.sender_pid, request.channel, request.target_nick, "unknown_sender")
      end
    else
      KickMutation.reply(request.sender_pid, request.channel, request.target_nick, "stale_channel")
    end

    {:noreply, state}
  end

  def handle_cast({:request_invite, %InviteOutbound{} = request}, state) do
    if state.projector do
      case Projector.uid_for_pid(state.projector, request.sender_pid) do
        {:ok, uid} ->
          snapshot = Projector.refresh_snapshot(state.projector)
          send(self(), {:invite_request_ready, request, uid, snapshot.cursor})

        :error ->
          InviteMutation.reply(request.sender_pid, request.channel, request.target_nick, "unknown_sender")
      end
    else
      InviteMutation.reply(request.sender_pid, request.channel, request.target_nick, "stale_channel")
    end

    {:noreply, state}
  end

  def handle_cast({:announce_invite, %LocalInviteNotice{} = request}, state) do
    if state.projector do
      Projector.refresh_snapshot(state.projector)

      with {:ok, sender_uid} <- Projector.uid_for_pid(state.projector, request.sender_pid),
           {:ok, target_uid} <- Projector.uid_for_pid(state.projector, request.target_pid) do
        send(self(), {:local_invite_notice_ready, request, sender_uid, target_uid})
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:dial, id}, state) do
    cond do
      not Map.has_key?(state.peers, id) or not dialer?(state.id, id) or MapSet.member?(state.suppressed, id) ->
        {:noreply, state}

      Map.has_key?(state.links, id) or Map.has_key?(state.dials, id) ->
        {:noreply, state}

      true ->
        parent = self()
        peer = Map.fetch!(state.peers, id)
        {pid, ref} = spawn_monitor(fn -> Peer.run_outbound(parent, state.id, state.network, state.listen, peer) end)
        {:noreply, %{state | dials: Map.put(state.dials, id, pid), dial_refs: Map.put(state.dial_refs, ref, id)}}
    end
  end

  def handle_info({:server_link_local_event, frame}, state) do
    maybe_reconcile_local_nick(frame, state)

    cursors =
      Enum.reduce(state.links, state.link_cursors, fn {id, pid}, cursors ->
        if frame["sequence"] > Map.fetch!(cursors, id) do
          enqueue_link(pid, {:link_frame, frame})
          Map.put(cursors, id, frame["sequence"])
        else
          cursors
        end
      end)

    {:noreply, %{state | link_cursors: cursors, local_cursor: max(state.local_cursor, frame["sequence"])}}
  end

  def handle_info({:server_link_local_delta, frames}, state) do
    sequence = hd(frames)["sequence"]

    cursors =
      Enum.reduce(state.links, state.link_cursors, fn {id, pid}, cursors ->
        if sequence > Map.fetch!(cursors, id) do
          enqueue_link(pid, {:link_delta, frames})
          Map.put(cursors, id, sequence)
        else
          cursors
        end
      end)

    local_channels =
      if sequence > state.local_cursor,
        do: apply_local_channel_delta(state.local_channels, frames),
        else: state.local_channels

    new_state =
      %{state | link_cursors: cursors, local_cursor: max(state.local_cursor, sequence), local_channels: local_channels}

    updated = maybe_refresh_channel_views(state, new_state)

    ChannelEvents.deliver_local_delta(
      state.replica,
      state.channel_view,
      updated.channel_view,
      frames
    )

    NetworkStats.publish(
      updated.indexes.network_stats,
      updated.replica,
      updated.routes,
      updated.links,
      updated.channel_view
    )

    {:noreply, updated}
  end

  def handle_info({:server_link_projector_overflow, %Overflow{} = overflow}, state) do
    Logger.warning(
      "server link projector subscriber overflow at #{overflow.epoch}/#{overflow.sequence}; restarting links"
    )

    {:stop, :projector_overflow, state}
  end

  def handle_info({:send_direct_ready, %DirectOutbound{} = outbound, sender_uid}, state) do
    local_sender = Memento.transaction!(fn -> Users.get_by_pid(outbound.sender_pid) end)
    current_uid = if state.projector, do: Projector.uid_for_pid(state.projector, outbound.sender_pid), else: :error

    updated =
      case {local_sender, current_uid, state.routes[outbound.target_origin],
            Replica.get_by_uid(state.replica, outbound.target_origin, outbound.target_uid)} do
        {{:ok, %{registered: true} = sender}, {:ok, ^sender_uid}, %Route{} = route, {:ok, _target}} ->
          queue_direct_message(state, outbound, sender_uid, route, sender)

        {{:ok, %{registered: true}}, {:ok, ^sender_uid}, _route, :error} ->
          direct_unavailable(state, outbound, :unknown_target)

        {{:ok, %{registered: true}}, {:ok, ^sender_uid}, _route, _target} ->
          direct_unavailable(state, outbound, :unavailable)

        _ ->
          state
      end

    {:noreply, updated}
  end

  def handle_info({:direct_request_expired, id}, state) do
    case Map.pop(state.direct_pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%DirectPending{} = request, pending} ->
        reply_direct_request(state, request, :unavailable)
        {:noreply, %{state | direct_pending: pending}}
    end
  end

  def handle_info({:send_channel_ready, %ChannelOutbound{} = outbound, sender_uid}, state) do
    current_uid =
      if state.projector, do: Projector.uid_for_pid(state.projector, outbound.sender_pid), else: {:ok, sender_uid}

    selected = state.channel_view[CaseMapping.normalize(outbound.channel)]

    with {:ok, ^sender_uid} <- current_uid,
         %ChannelView{} = view <- selected,
         {:ok, %ChannelLocalDelivery{} = delivery} <-
           Memento.transaction!(fn -> ChannelMessage.prepare_local(outbound, view) end) do
      dispatch_accepted_channel(state, outbound, sender_uid, delivery)
    else
      {:error, reason} -> reply_channel_error(outbound, reason)
      _ -> reply_channel_unavailable(outbound)
    end

    {:noreply, state}
  end

  def handle_info({:topic_request_ready, sender_pid, uid, authority, channel, text, cursor}, state) do
    if state.local_cursor < cursor do
      TopicMutation.reply(sender_pid, channel, "stale_authority")
      {:noreply, state}
    else
      {:noreply, send_topic_request(state, sender_pid, uid, authority, channel, text)}
    end
  end

  def handle_info({:topic_request_expired, id}, state) do
    case Map.pop(state.topic_pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%TopicPending{} = request, pending} ->
        reply_topic_request(state, request, "stale_authority")
        {:noreply, %{state | topic_pending: pending}}
    end
  end

  def handle_info({:mode_request_ready, %Outbound{} = request, uid, cursor}, state) do
    if state.local_cursor < cursor do
      ModeMutation.reply(request.sender_pid, request.channel, "stale_authority")
      {:noreply, state}
    else
      {:noreply, send_mode_request(state, request, uid)}
    end
  end

  def handle_info({:mode_request_expired, id}, state) do
    case Map.pop(state.mode_pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%ModePending{} = request, pending} ->
        reply_mode_request(state, request, "stale_authority")
        {:noreply, %{state | mode_pending: pending}}
    end
  end

  def handle_info({:kick_request_ready, %KickOutbound{} = request, uid, cursor}, state) do
    if state.local_cursor < cursor do
      KickMutation.reply(request.sender_pid, request.channel, request.target_nick, "stale_channel")
      {:noreply, state}
    else
      {:noreply, send_kick_request(state, request, uid)}
    end
  end

  def handle_info({:kick_request_expired, id}, state) do
    case Map.pop(state.kick_pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%KickPending{} = request, pending} ->
        reply_kick_request(state, request, "stale_channel")
        {:noreply, %{state | kick_pending: pending}}
    end
  end

  def handle_info({:invite_request_ready, %InviteOutbound{} = request, uid, cursor}, state) do
    if state.local_cursor < cursor do
      InviteMutation.reply(request.sender_pid, request.channel, request.target_nick, "stale_channel")
      {:noreply, state}
    else
      {:noreply, send_invite_request(state, request, uid)}
    end
  end

  def handle_info({:local_invite_notice_ready, %LocalInviteNotice{} = request, sender_uid, target_uid}, state) do
    view = state.channel_view[CaseMapping.normalize(request.channel)]

    if match?(%ChannelView{}, view) and view.channel["creator"] == request.channel_ref.creator and
         view.channel["created_at"] == request.channel_ref.created_at do
      notice = %InviteNotice{
        origin: state.id,
        epoch: state.local_epoch,
        id: UserPayload.new_uid(),
        uid: sender_uid,
        sender_mask: request.sender_mask,
        sender_account: request.sender_account,
        target_origin: state.id,
        target_uid: target_uid,
        target_nick: request.target_nick,
        channel: request.channel,
        channel_ref: request.channel_ref,
        ttl: 64
      }

      enqueue_channel_if_valid(state, InviteMutation.notice_frame(notice))
    end

    {:noreply, state}
  end

  def handle_info({:invite_request_expired, id}, state) do
    case Map.pop(state.invite_pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%InvitePending{} = request, pending} ->
        reply_invite_request(state, request, "stale_channel", nil)
        {:noreply, %{state | invite_pending: pending}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      Map.has_key?(state.pending_refs, ref) ->
        pid = Map.fetch!(state.pending_refs, ref)
        {:noreply, release_pending(state, pid)}

      Map.has_key?(state.link_refs, ref) ->
        id = Map.fetch!(state.link_refs, ref)
        Logger.warning("server link lost with #{id}")

        {routes, replica, removed} = drop_routes_via(state, id)
        Directory.sync(state.indexes.directory, state.replica, replica)
        UserEvents.deliver_departures(state.replica, replica, state.channel_view, "Server link lost")
        notify_route_down(state, removed, id)

        new_state = %{
          state
          | links: Map.delete(state.links, id),
            link_cursors: Map.delete(state.link_cursors, id),
            link_refs: Map.delete(state.link_refs, ref),
            routes: routes,
            replica: replica
        }

        new_state = expire_stale_mutations(new_state, state.routes)

        if dialer?(state.id, id) and not MapSet.member?(state.suppressed, id),
          do: Process.send_after(self(), {:dial, id}, @retry_ms)

        updated = maybe_refresh_channel_views(state, new_state)
        ChannelEvents.deliver_route_lists(state.channel_view, updated.channel_view)

        NetworkStats.publish(
          updated.indexes.network_stats,
          updated.replica,
          updated.routes,
          updated.links,
          updated.channel_view
        )

        {:noreply, updated}

      Map.has_key?(state.dial_refs, ref) ->
        id = Map.fetch!(state.dial_refs, ref)
        new_state = %{state | dials: Map.delete(state.dials, id), dial_refs: Map.delete(state.dial_refs, ref)}

        if not Map.has_key?(state.links, id) and not MapSet.member?(state.suppressed, id),
          do: Process.send_after(self(), {:dial, id}, @retry_ms)

        {:noreply, new_state}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    :ssl.close(state.listener)
    :ok
  end

  defp dialer?(local_id, peer_id), do: String.downcase(local_id) < String.downcase(peer_id)

  defp maybe_suppress_topology_error({:reply, {:error, reason}, state}, id) when reason in @topology_errors do
    {:reply, {:error, reason}, %{state | suppressed: MapSet.put(state.suppressed, id)}}
  end

  defp maybe_suppress_topology_error(reply, _id), do: reply

  defp handle_remote_frame(state, peer_id, %{"type" => "route_up"} = frame) do
    origin = frame["origin"]

    case route_up_action(state, peer_id, frame) do
      :same ->
        {:reply, :ok, state}

      :replace ->
        {routes, replica, removed} = drop_route_tree(state, origin)
        notify_route_down(state, removed, peer_id)
        route = %Route{via: peer_id, epoch: frame["epoch"], path: frame["path"] ++ [state.id]}
        updated = %{state | routes: Map.put(routes, origin, route), replica: replica}
        {:reply, :ok, expire_stale_mutations(updated, state.routes)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_remote_frame(state, peer_id, %{"type" => "route_down"} = frame) do
    incoming_epoch = frame["epoch"]

    case state.routes[frame["origin"]] do
      %{via: ^peer_id, epoch: ^incoming_epoch} ->
        {routes, replica, removed} = drop_route_tree(state, frame["origin"])
        notify_route_down(state, removed, peer_id)
        updated = %{state | routes: routes, replica: replica}
        {:reply, :ok, expire_stale_mutations(updated, state.routes)}

      _ ->
        {:reply, {:error, :unknown_route}, state}
    end
  end

  defp handle_remote_frame(state, peer_id, %{"type" => "direct_message"} = frame) do
    origin = frame["origin"]
    incoming_epoch = frame["epoch"]

    with %{via: ^peer_id, epoch: ^incoming_epoch} <- state.routes[origin],
         {:ok, sender} <- Replica.get_by_uid(state.replica, origin, frame["from_uid"]) do
      route_direct_message(state, peer_id, frame, sender)
    else
      _ -> {:reply, {:error, :unknown_sender}, state}
    end
  end

  defp handle_remote_frame(state, peer_id, %{"type" => "direct_result"} = frame) do
    origin = frame["origin"]
    incoming_epoch = frame["epoch"]

    case state.routes[origin] do
      %Route{via: ^peer_id, epoch: ^incoming_epoch} -> route_direct_result(state, peer_id, frame)
      _ -> {:reply, {:error, :unknown_route}, state}
    end
  end

  defp handle_remote_frame(state, peer_id, %{"type" => "channel_message"} = frame) do
    origin = frame["origin"]
    incoming_epoch = frame["epoch"]

    with %{via: ^peer_id, epoch: ^incoming_epoch} <- state.routes[origin],
         {:ok, sender} <- Replica.get_by_uid(state.replica, origin, frame["from_uid"]),
         {:new, seen} <- MessageReplay.accept(state.replays.messages, origin, incoming_epoch, frame["id"]) do
      if ChannelMessage.accepted_identity?(state.channel_view, state.replica, frame) do
        ChannelMessage.deliver(state.channel_view, sender, frame)
        forward_channel_message(state, peer_id, frame)
      end

      {:reply, :ok, %{state | replays: %{state.replays | messages: seen}}}
    else
      {:duplicate, seen} -> {:reply, :ok, %{state | replays: %{state.replays | messages: seen}}}
      _ -> {:reply, {:error, :unknown_sender}, state}
    end
  end

  defp handle_remote_frame(state, peer_id, %{"type" => "topic_request"} = frame) do
    origin = frame["origin"]
    incoming_epoch = frame["epoch"]

    case state.routes[origin] do
      %{via: ^peer_id, epoch: ^incoming_epoch} -> route_topic_request(state, peer_id, frame)
      _ -> {:reply, {:error, :unknown_route}, state}
    end
  end

  defp handle_remote_frame(state, peer_id, %{"type" => "topic_result"} = frame) do
    origin = frame["origin"]
    incoming_epoch = frame["epoch"]

    case state.routes[origin] do
      %{via: ^peer_id, epoch: ^incoming_epoch} -> route_topic_result(state, peer_id, frame)
      _ -> {:reply, {:error, :unknown_route}, state}
    end
  end

  defp handle_remote_frame(state, peer_id, %{"type" => "mode_request"} = frame) do
    origin = frame["origin"]
    incoming_epoch = frame["epoch"]

    case state.routes[origin] do
      %{via: ^peer_id, epoch: ^incoming_epoch} -> route_mode_request(state, peer_id, frame)
      _ -> {:reply, {:error, :unknown_route}, state}
    end
  end

  defp handle_remote_frame(state, peer_id, %{"type" => "mode_result"} = frame) do
    origin = frame["origin"]
    incoming_epoch = frame["epoch"]

    case state.routes[origin] do
      %{via: ^peer_id, epoch: ^incoming_epoch} -> route_mode_result(state, peer_id, frame)
      _ -> {:reply, {:error, :unknown_route}, state}
    end
  end

  defp handle_remote_frame(state, peer_id, %{"type" => "kick_request"} = frame) do
    origin = frame["origin"]
    incoming_epoch = frame["epoch"]

    case state.routes[origin] do
      %{via: ^peer_id, epoch: ^incoming_epoch} -> route_kick_request(state, peer_id, frame)
      _ -> {:reply, {:error, :unknown_route}, state}
    end
  end

  defp handle_remote_frame(state, peer_id, %{"type" => "kick_result"} = frame) do
    origin = frame["origin"]
    incoming_epoch = frame["epoch"]

    case state.routes[origin] do
      %{via: ^peer_id, epoch: ^incoming_epoch} -> route_kick_result(state, peer_id, frame)
      _ -> {:reply, {:error, :unknown_route}, state}
    end
  end

  defp handle_remote_frame(state, peer_id, %{"type" => "invite_request"} = frame) do
    origin = frame["origin"]
    incoming_epoch = frame["epoch"]

    case state.routes[origin] do
      %{via: ^peer_id, epoch: ^incoming_epoch} -> route_invite_request(state, peer_id, frame)
      _ -> {:reply, {:error, :unknown_route}, state}
    end
  end

  defp handle_remote_frame(state, peer_id, %{"type" => "invite_result"} = frame) do
    origin = frame["origin"]
    incoming_epoch = frame["epoch"]

    case state.routes[origin] do
      %{via: ^peer_id, epoch: ^incoming_epoch} -> route_invite_result(state, peer_id, frame)
      _ -> {:reply, {:error, :unknown_route}, state}
    end
  end

  defp handle_remote_frame(state, peer_id, %{"type" => "invite_notice"} = frame) do
    origin = frame["origin"]
    epoch = frame["epoch"]

    case state.routes[origin] do
      %{via: ^peer_id, epoch: ^epoch} ->
        route_invite_notice(state, peer_id, frame)

      _ ->
        {:reply, {:error, :unknown_route}, state}
    end
  end

  defp handle_remote_frame(state, peer_id, frame) do
    origin = frame["origin"]
    incoming_epoch = frame["epoch"]

    case state.routes[origin] do
      %{via: ^peer_id, epoch: ^incoming_epoch} ->
        apply_remote_data(state, peer_id, frame)

      _ ->
        {:reply, {:error, :unknown_route}, state}
    end
  end

  defp route_invite_notice(state, peer_id, frame) do
    case MessageReplay.accept(state.replays.invite_notices, frame["origin"], frame["epoch"], frame["id"]) do
      {:new, seen} ->
        notice = InviteMutation.notice_from_frame(frame)
        if notice.target_origin != state.id, do: InviteMutation.deliver_notice(notice)
        forward_channel_message(state, peer_id, frame)
        {:reply, :ok, %{state | replays: %{state.replays | invite_notices: seen}}}

      {:duplicate, seen} ->
        {:reply, :ok, %{state | replays: %{state.replays | invite_notices: seen}}}
    end
  end

  defp route_up_action(state, peer_id, frame) do
    path = frame["path"]

    with :ok <- validate_route_path(state.id, peer_id, path),
         :ok <- route_capacity(state, frame["origin"]) do
      route_existing_action(state.routes[frame["origin"]], peer_id, frame, state.id)
    end
  end

  defp route_capacity(state, origin) do
    if Map.has_key?(state.routes, origin) or map_size(state.routes) < state.max_remote_origins,
      do: :ok,
      else: {:error, :route_capacity}
  end

  defp route_direct_message(%{id: id, projector: projector} = state, _peer_id, %{"to_origin" => id} = frame, sender) do
    case DirectReplay.check(state.replays.direct, frame) do
      {:new, replay} ->
        decision = if projector, do: DirectMessage.deliver(projector, sender, frame), else: {:error, :unknown_target}
        code = DirectMessage.result_code(decision)
        away = if frame["command"] == "PRIVMSG", do: DirectMessage.result_away(decision), else: nil
        updated = %{state | replays: %{state.replays | direct: DirectReplay.remember(replay, frame, code, away)}}
        send_direct_result(updated, frame, code, away)
        {:reply, :ok, updated}

      {:duplicate, %DirectReplayEntry{code: code, away: away}, replay} ->
        updated = %{state | replays: %{state.replays | direct: replay}}
        send_direct_result(updated, frame, code, away)
        {:reply, :ok, updated}

      {:conflict, replay} ->
        {:reply, {:error, :reused_message_id}, %{state | replays: %{state.replays | direct: replay}}}
    end
  end

  defp route_direct_message(state, peer_id, frame, _sender) do
    case state.routes[frame["to_origin"]] do
      %{via: via} when via != peer_id -> forward_direct_message(state, via, frame)
      _ -> :ok
    end

    {:reply, :ok, state}
  end

  defp send_direct_result(state, frame, code, away) do
    result = %{
      "type" => "direct_result",
      "origin" => state.id,
      "epoch" => state.local_epoch,
      "to_origin" => frame["origin"],
      "to_uid" => frame["from_uid"],
      "id" => frame["id"],
      "code" => code,
      "away" => away,
      "ttl" => 64
    }

    if Frame.validate(result) == :ok, do: forward_mutation_frame(state, nil, result)
  end

  defp route_direct_result(
         %{id: id} = state,
         _peer_id,
         %{"to_origin" => id, "to_uid" => uid, "origin" => authority, "epoch" => epoch} = frame
       ) do
    case Map.get(state.direct_pending, frame["id"]) do
      nil ->
        {:reply, :ok, state}

      %DirectPending{uid: ^uid, authority: ^authority, authority_epoch: ^epoch} = request ->
        code = DirectMessage.result_reason(frame["code"])
        reply_direct_request(state, request, code, frame["away"])
        {:reply, :ok, %{state | direct_pending: Map.delete(state.direct_pending, frame["id"])}}

      _ ->
        {:reply, {:error, :invalid_direct_result}, state}
    end
  end

  defp route_direct_result(state, peer_id, frame) do
    forward_mutation_frame(state, peer_id, frame)
    {:reply, :ok, state}
  end

  defp queue_direct_message(state, %DirectOutbound{} = outbound, sender_uid, %Route{} = route, sender) do
    frame = %{
      "type" => "direct_message",
      "origin" => state.id,
      "epoch" => state.local_epoch,
      "from_uid" => sender_uid,
      "to_origin" => outbound.target_origin,
      "to_uid" => outbound.target_uid,
      "command" => outbound.command,
      "text" => outbound.text,
      "tags" => outbound.tags,
      "ttl" => 64,
      "id" => UserPayload.new_uid(),
      "sent_at" => DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    }

    capacity? = map_size(state.direct_pending) < @max_pending_directs

    case {Frame.validate(frame), Map.fetch(state.links, route.via), capacity?} do
      {:ok, {:ok, link}, true} ->
        if enqueue_link(link, {:link_frame, frame}) == :ok do
          track_direct_request(state, outbound, sender_uid, route, frame["id"], frame["sent_at"], sender)
        else
          direct_unavailable(state, outbound, :unavailable)
        end

      _ ->
        direct_unavailable(state, outbound, :unavailable)
    end
  end

  defp track_direct_request(state, %DirectOutbound{} = outbound, uid, %Route{} = route, id, sent_at, sender) do
    request = %DirectPending{
      uid: uid,
      authority: outbound.target_origin,
      authority_epoch: route.epoch,
      target_uid: outbound.target_uid,
      target_nick: outbound.target_nick,
      id: id,
      sent_at: sent_at,
      sender: sender,
      command: outbound.command,
      text: outbound.text,
      tags: outbound.tags
    }

    Process.send_after(self(), {:direct_request_expired, id}, @direct_request_timeout_ms)
    %{state | direct_pending: Map.put(state.direct_pending, id, request)}
  end

  defp direct_unavailable(state, %DirectOutbound{} = outbound, code) do
    DirectMessage.reply(outbound.sender_pid, outbound.target_nick, code, outbound.command)
    state
  end

  defp reply_direct_request(state, request, code), do: reply_direct_request(state, request, code, nil)

  defp reply_direct_request(%{projector: projector}, %DirectPending{} = request, code, away)
       when not is_nil(projector) do
    case Projector.pid_for_uid(projector, request.uid) do
      {:ok, pid} ->
        DirectMessage.reply(pid, request.target_nick, code, request.command)

        if code == :ok, do: accept_direct_request(pid, request, away)

      :error ->
        :ok
    end
  end

  defp reply_direct_request(_state, _request, _code, _away), do: :ok

  defp accept_direct_request(pid, %DirectPending{command: "PRIVMSG"} = request, away) do
    DirectMessage.accepted(pid, request)
    DirectMessage.away_reply(pid, request.target_nick, away)
  end

  defp accept_direct_request(pid, %DirectPending{} = request, _away), do: DirectMessage.accepted(pid, request)

  defp send_topic_request(state, sender_pid, uid, authority, channel, text) do
    key = CaseMapping.normalize(channel)

    local_source =
      Memento.transaction!(fn ->
        {Users.get_by_pid(sender_pid), UserChannels.get_by_user_pid_and_channel_name(sender_pid, channel)}
      end)

    case {local_source, state.channel_view[key], state.routes[authority]} do
      {{{:ok, %{registered: true}}, {:ok, _membership}}, %ChannelView{origin: ^authority}, %{via: via, epoch: epoch}}
      when authority != state.id ->
        pending = %TopicPending{uid: uid, authority: authority, authority_epoch: epoch, channel: key}
        queue_topic_request(state, sender_pid, pending, channel, text, via)

      _ ->
        TopicMutation.reply(sender_pid, channel, "stale_authority")
        state
    end
  end

  defp send_mode_request(state, %Outbound{} = request, uid) do
    key = CaseMapping.normalize(request.channel)

    local_source =
      Memento.transaction!(fn ->
        {Users.get_by_pid(request.sender_pid),
         UserChannels.get_by_user_pid_and_channel_name(request.sender_pid, request.channel)}
      end)

    case {local_source, state.channel_view[key], state.routes[request.authority]} do
      {{{:ok, %{registered: true}}, {:ok, _membership}}, %ChannelView{origin: origin}, %{via: via, epoch: epoch}}
      when origin == request.authority and origin != state.id ->
        pending = %ModePending{uid: uid, authority: origin, authority_epoch: epoch, channel: key}
        queue_mode_request(state, request, pending, via)

      _ ->
        ModeMutation.reply(request.sender_pid, request.channel, "stale_authority")
        state
    end
  end

  defp send_kick_request(state, %KickOutbound{} = request, uid) do
    key = CaseMapping.normalize(request.channel)

    local_source =
      Memento.transaction!(fn ->
        {Users.get_by_pid(request.sender_pid),
         UserChannels.get_by_user_pid_and_channel_name(request.sender_pid, request.channel)}
      end)

    view = state.channel_view[key]
    route = state.routes[request.target_origin]

    valid_target? =
      match?(%ChannelView{}, view) and
        Enum.any?(view.remote_members, fn member ->
          member.origin == request.target_origin and member.member["uid"] == request.target_uid
        end)

    case {local_source, route, valid_target?} do
      {{{:ok, %{registered: true}}, {:ok, membership}}, %{via: via, epoch: epoch}, true}
      when request.target_origin != state.id ->
        if :o in membership.modes do
          pending = %KickPending{
            uid: uid,
            authority: request.target_origin,
            authority_epoch: epoch,
            target_uid: request.target_uid,
            target_nick: request.target_nick,
            channel: key
          }

          queue_kick_request(state, request, pending, via)
        else
          kick_request_unavailable(state, request, "operator_required")
        end

      _ ->
        kick_request_unavailable(state, request, "stale_channel")
    end
  end

  defp send_invite_request(state, %InviteOutbound{} = request, uid) do
    key = CaseMapping.normalize(request.channel)

    local_source =
      Memento.transaction!(fn ->
        {Users.get_by_pid(request.sender_pid),
         UserChannels.get_by_user_pid_and_channel_name(request.sender_pid, request.channel),
         RegisteredChannels.get_by_name(request.channel)}
      end)

    view = state.channel_view[key]
    route = state.routes[request.target_origin]

    case {local_source, view, route, Replica.get_by_uid(state.replica, request.target_origin, request.target_uid)} do
      {{{:ok, %{registered: true} = inviter}, {:ok, membership}, {:error, :registered_channel_not_found}},
       %ChannelView{} = selected, %{via: via, epoch: epoch}, {:ok, _target}}
      when request.target_origin != state.id ->
        authorize_and_queue_invite(state, request, uid, inviter, membership, selected, via, epoch)

      _ ->
        invite_request_unavailable(state, request, "stale_channel")
    end
  end

  defp authorize_and_queue_invite(state, request, uid, inviter, membership, view, via, epoch) do
    invite_only = Enum.any?(view.channel["modes"], &(&1["name"] == "i"))

    target_member =
      Enum.any?(view.remote_members, fn member ->
        member.origin == request.target_origin and member.member["uid"] == request.target_uid
      end)

    cond do
      invite_only and :o not in membership.modes ->
        invite_request_unavailable(state, request, "operator_required")

      target_member ->
        invite_request_unavailable(state, request, "already_on_channel")

      true ->
        pending = %InvitePending{
          uid: uid,
          sender_mask: Protocol.user_mask(inviter),
          sender_account: inviter.identified_as,
          authority: request.target_origin,
          authority_epoch: epoch,
          target_uid: request.target_uid,
          target_nick: request.target_nick,
          channel: CaseMapping.normalize(request.channel),
          channel_ref: %InviteMutation.ChannelRef{
            creator: view.channel["creator"],
            created_at: view.channel["created_at"]
          }
        }

        queue_invite_request(state, request, pending, via)
    end
  end

  defp queue_invite_request(state, request, pending, via) do
    frame = %{
      "type" => "invite_request",
      "origin" => state.id,
      "epoch" => state.local_epoch,
      "from_uid" => pending.uid,
      "to_origin" => pending.authority,
      "to_uid" => pending.target_uid,
      "channel" => request.channel,
      "id" => UserPayload.new_uid(),
      "ttl" => 64
    }

    case {Frame.validate(frame), Map.fetch(state.links, via), map_size(state.invite_pending) < @max_pending_invites} do
      {:ok, {:ok, link}, true} ->
        if enqueue_link(link, {:link_frame, frame}) == :ok do
          Process.send_after(self(), {:invite_request_expired, frame["id"]}, @invite_request_timeout_ms)
          %{state | invite_pending: Map.put(state.invite_pending, frame["id"], pending)}
        else
          invite_request_unavailable(state, request, "stale_channel")
        end

      _ ->
        invite_request_unavailable(state, request, "stale_channel")
    end
  end

  defp invite_request_unavailable(state, request, code) do
    InviteMutation.reply(request.sender_pid, request.channel, request.target_nick, code)
    state
  end

  defp queue_kick_request(state, request, pending, via) do
    frame = %{
      "type" => "kick_request",
      "origin" => state.id,
      "epoch" => state.local_epoch,
      "from_uid" => pending.uid,
      "to_origin" => pending.authority,
      "to_uid" => pending.target_uid,
      "channel" => request.channel,
      "reason" => request.reason,
      "id" => UserPayload.new_uid(),
      "ttl" => 64
    }

    case {Frame.validate(frame), Map.fetch(state.links, via), map_size(state.kick_pending) < @max_pending_kicks} do
      {:ok, {:ok, link}, true} ->
        if enqueue_link(link, {:link_frame, frame}) == :ok do
          Process.send_after(self(), {:kick_request_expired, frame["id"]}, @kick_request_timeout_ms)
          %{state | kick_pending: Map.put(state.kick_pending, frame["id"], pending)}
        else
          kick_request_unavailable(state, request, "stale_channel")
        end

      _ ->
        kick_request_unavailable(state, request, "stale_channel")
    end
  end

  defp kick_request_unavailable(state, request, code) do
    KickMutation.reply(request.sender_pid, request.channel, request.target_nick, code)
    state
  end

  defp queue_mode_request(state, request, pending, via) do
    frame = %{
      "type" => "mode_request",
      "origin" => state.id,
      "epoch" => state.local_epoch,
      "from_uid" => pending.uid,
      "to_origin" => pending.authority,
      "channel" => request.channel,
      "modes" => request.mode_string,
      "values" => request.values,
      "id" => UserPayload.new_uid(),
      "ttl" => 64
    }

    case {Frame.validate(frame), Map.fetch(state.links, via), map_size(state.mode_pending) < @max_pending_modes} do
      {:ok, {:ok, link}, true} -> enqueue_mode_request(state, request, pending, frame, link)
      _ -> mode_request_unavailable(state, request)
    end
  end

  defp enqueue_mode_request(state, request, pending, frame, link) do
    if enqueue_link(link, {:link_frame, frame}) == :ok do
      Process.send_after(self(), {:mode_request_expired, frame["id"]}, @mode_request_timeout_ms)
      %{state | mode_pending: Map.put(state.mode_pending, frame["id"], pending)}
    else
      mode_request_unavailable(state, request)
    end
  end

  defp mode_request_unavailable(state, request) do
    ModeMutation.reply(request.sender_pid, request.channel, "stale_authority")
    state
  end

  defp queue_topic_request(state, sender_pid, %TopicPending{} = pending, channel, text, via) do
    frame = %{
      "type" => "topic_request",
      "origin" => state.id,
      "epoch" => state.local_epoch,
      "from_uid" => pending.uid,
      "to_origin" => pending.authority,
      "channel" => channel,
      "text" => text,
      "id" => UserPayload.new_uid(),
      "ttl" => 64
    }

    case {Frame.validate(frame), Map.fetch(state.links, via), map_size(state.topic_pending) < @max_pending_topics} do
      {:ok, {:ok, link}, true} ->
        enqueue_topic_request(state, frame, link, pending, sender_pid)

      _ ->
        TopicMutation.reply(sender_pid, channel, "stale_authority")
        state
    end
  end

  defp enqueue_topic_request(state, frame, link, pending, sender_pid) do
    if enqueue_link(link, {:link_frame, frame}) == :ok do
      Process.send_after(self(), {:topic_request_expired, frame["id"]}, @topic_request_timeout_ms)
      %{state | topic_pending: Map.put(state.topic_pending, frame["id"], pending)}
    else
      TopicMutation.reply(sender_pid, pending.channel, "stale_authority")
      state
    end
  end

  defp reply_topic_request(%{projector: projector}, %TopicPending{} = request, code) when not is_nil(projector) do
    case Projector.pid_for_uid(projector, request.uid) do
      {:ok, pid} -> TopicMutation.reply(pid, request.channel, code)
      :error -> :ok
    end
  end

  defp reply_topic_request(_state, _request, _code), do: :ok

  defp route_topic_request(%{id: id} = state, _peer_id, %{"to_origin" => id} = frame) do
    key = CaseMapping.normalize(frame["channel"])

    decision =
      case state.channel_view[key] do
        %ChannelView{origin: ^id} = view ->
          TopicMutation.apply(TopicMutation.from_frame(frame), state.replica, view, id)

        _ ->
          {:error, :stale_authority}
      end

    result = %{
      "type" => "topic_result",
      "origin" => id,
      "epoch" => state.local_epoch,
      "to_origin" => frame["origin"],
      "to_uid" => frame["from_uid"],
      "channel" => frame["channel"],
      "id" => frame["id"],
      "code" => TopicMutation.result_code(decision),
      "ttl" => 64
    }

    if Frame.validate(result) == :ok, do: forward_mutation_frame(state, nil, result)
    {:reply, :ok, state}
  end

  defp route_topic_request(state, peer_id, frame) do
    case Replica.get_by_uid(state.replica, frame["origin"], frame["from_uid"]) do
      {:ok, _sender} ->
        forward_mutation_frame(state, peer_id, frame)
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :unknown_sender}, state}
    end
  end

  defp route_topic_result(
         %{id: id} = state,
         _peer_id,
         %{"to_origin" => id, "to_uid" => uid, "origin" => authority, "epoch" => epoch, "channel" => name} = frame
       ) do
    case Map.get(state.topic_pending, frame["id"]) do
      nil ->
        {:reply, :ok, state}

      %TopicPending{uid: ^uid, authority: ^authority, authority_epoch: ^epoch, channel: channel} = request ->
        if channel == CaseMapping.normalize(name) do
          reply_topic_request(state, request, frame["code"])
          {:reply, :ok, %{state | topic_pending: Map.delete(state.topic_pending, frame["id"])}}
        else
          {:reply, {:error, :invalid_topic_result}, state}
        end

      _ ->
        {:reply, {:error, :invalid_topic_result}, state}
    end
  end

  defp route_topic_result(state, peer_id, frame) do
    forward_mutation_frame(state, peer_id, frame)
    {:reply, :ok, state}
  end

  defp reply_mode_request(%{projector: projector}, %ModePending{} = request, code) when not is_nil(projector) do
    case Projector.pid_for_uid(projector, request.uid) do
      {:ok, pid} -> ModeMutation.reply(pid, request.channel, code)
      :error -> :ok
    end
  end

  defp reply_mode_request(_state, _request, _code), do: :ok

  defp reply_kick_request(%{projector: projector}, %KickPending{} = request, code)
       when not is_nil(projector) do
    case Projector.pid_for_uid(projector, request.uid) do
      {:ok, pid} -> KickMutation.reply(pid, request.channel, request.target_nick, code)
      :error -> :ok
    end
  end

  defp reply_kick_request(_state, _request, _code), do: :ok

  defp reply_invite_request(%{projector: projector}, %InvitePending{} = request, code, away)
       when not is_nil(projector) do
    case Projector.pid_for_uid(projector, request.uid) do
      {:ok, pid} -> InviteMutation.reply(pid, request.channel, request.target_nick, code, away, request.channel_ref)
      :error -> :ok
    end
  end

  defp reply_invite_request(_state, _request, _code, _away), do: :ok

  defp expire_stale_mutations(state, prior_routes) do
    directs =
      Enum.reduce(state.direct_pending, %{}, fn {id, %DirectPending{} = request}, pending ->
        if same_pending_route?(request.authority, request.authority_epoch, prior_routes, state.routes) do
          Map.put(pending, id, request)
        else
          reply_direct_request(state, request, :unavailable)
          pending
        end
      end)

    topics =
      Enum.reduce(state.topic_pending, %{}, fn {id, %TopicPending{} = request}, pending ->
        if same_pending_route?(request.authority, request.authority_epoch, prior_routes, state.routes) do
          Map.put(pending, id, request)
        else
          reply_topic_request(state, request, "stale_authority")
          pending
        end
      end)

    modes =
      Enum.reduce(state.mode_pending, %{}, fn {id, %ModePending{} = request}, pending ->
        if same_pending_route?(request.authority, request.authority_epoch, prior_routes, state.routes) do
          Map.put(pending, id, request)
        else
          reply_mode_request(state, request, "stale_authority")
          pending
        end
      end)

    kicks =
      Enum.reduce(state.kick_pending, %{}, fn {id, %KickPending{} = request}, pending ->
        if same_pending_route?(request.authority, request.authority_epoch, prior_routes, state.routes) do
          Map.put(pending, id, request)
        else
          reply_kick_request(state, request, "stale_channel")
          pending
        end
      end)

    invites =
      Enum.reduce(state.invite_pending, %{}, fn {id, %InvitePending{} = request}, pending ->
        if same_pending_route?(request.authority, request.authority_epoch, prior_routes, state.routes) do
          Map.put(pending, id, request)
        else
          reply_invite_request(state, request, "stale_channel", nil)
          pending
        end
      end)

    %{
      state
      | direct_pending: directs,
        topic_pending: topics,
        mode_pending: modes,
        kick_pending: kicks,
        invite_pending: invites
    }
  end

  defp same_pending_route?(authority, epoch, prior_routes, current_routes) do
    prior = Map.get(prior_routes, authority)
    current = Map.get(current_routes, authority)
    not is_nil(prior) and prior == current and current.epoch == epoch
  end

  defp route_mode_request(%{id: id} = state, _peer_id, %{"to_origin" => id} = frame) do
    key = CaseMapping.normalize(frame["channel"])

    decision =
      case state.channel_view[key] do
        %ChannelView{origin: ^id} = view ->
          ModeMutation.apply(ModeMutation.from_frame(frame), state.replica, view, id)

        _ ->
          {:error, :stale_authority}
      end

    result = %{
      "type" => "mode_result",
      "origin" => id,
      "epoch" => state.local_epoch,
      "to_origin" => frame["origin"],
      "to_uid" => frame["from_uid"],
      "channel" => frame["channel"],
      "id" => frame["id"],
      "code" => ModeMutation.result_code(decision),
      "ttl" => 64
    }

    if Frame.validate(result) == :ok, do: forward_mutation_frame(state, nil, result)
    {:reply, :ok, state}
  end

  defp route_mode_request(state, peer_id, frame) do
    case Replica.get_by_uid(state.replica, frame["origin"], frame["from_uid"]) do
      {:ok, _sender} ->
        forward_mutation_frame(state, peer_id, frame)
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :unknown_sender}, state}
    end
  end

  defp route_mode_result(
         %{id: id} = state,
         _peer_id,
         %{"to_origin" => id, "to_uid" => uid, "origin" => authority, "epoch" => epoch, "channel" => name} = frame
       ) do
    case Map.get(state.mode_pending, frame["id"]) do
      nil ->
        {:reply, :ok, state}

      %ModePending{uid: ^uid, authority: ^authority, authority_epoch: ^epoch, channel: channel} = request ->
        if channel == CaseMapping.normalize(name) do
          reply_mode_request(state, request, frame["code"])
          {:reply, :ok, %{state | mode_pending: Map.delete(state.mode_pending, frame["id"])}}
        else
          {:reply, {:error, :invalid_mode_result}, state}
        end

      _ ->
        {:reply, {:error, :invalid_mode_result}, state}
    end
  end

  defp route_mode_result(state, peer_id, frame) do
    forward_mutation_frame(state, peer_id, frame)
    {:reply, :ok, state}
  end

  defp route_kick_request(%{id: id} = state, _peer_id, %{"to_origin" => id} = frame) do
    case KickReplay.check(state.replays.kick, frame) do
      {:new, replay} ->
        key = CaseMapping.normalize(frame["channel"])

        decision =
          case state.channel_view[key] do
            %ChannelView{} = view when not is_nil(state.projector) ->
              KickMutation.apply_remote(KickMutation.from_frame(frame), state.replica, view, id, state.projector)

            _ ->
              {:error, :stale_channel}
          end

        code = KickMutation.result_code(decision)
        updated = %{state | replays: %{state.replays | kick: KickReplay.remember(replay, frame, code)}}
        send_kick_result(updated, frame, code)
        {:reply, :ok, updated}

      {:duplicate, %KickReplayEntry{code: code}, replay} ->
        updated = %{state | replays: %{state.replays | kick: replay}}
        send_kick_result(updated, frame, code)
        {:reply, :ok, updated}

      {:conflict, replay} ->
        {:reply, {:error, :reused_message_id}, %{state | replays: %{state.replays | kick: replay}}}
    end
  end

  defp route_kick_request(state, peer_id, frame) do
    case Replica.get_by_uid(state.replica, frame["origin"], frame["from_uid"]) do
      {:ok, _sender} ->
        forward_mutation_frame(state, peer_id, frame)
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :unknown_sender}, state}
    end
  end

  defp send_kick_result(state, frame, code) do
    result = %{
      "type" => "kick_result",
      "origin" => state.id,
      "epoch" => state.local_epoch,
      "to_origin" => frame["origin"],
      "to_uid" => frame["from_uid"],
      "target_uid" => frame["to_uid"],
      "channel" => frame["channel"],
      "id" => frame["id"],
      "code" => code,
      "ttl" => 64
    }

    if Frame.validate(result) == :ok, do: forward_mutation_frame(state, nil, result)
  end

  defp route_kick_result(
         %{id: id} = state,
         _peer_id,
         %{
           "to_origin" => id,
           "to_uid" => uid,
           "origin" => authority,
           "epoch" => epoch,
           "target_uid" => target_uid,
           "channel" => name
         } = frame
       ) do
    case Map.get(state.kick_pending, frame["id"]) do
      nil ->
        {:reply, :ok, state}

      %KickPending{uid: ^uid, authority: ^authority, authority_epoch: ^epoch, target_uid: ^target_uid} =
          request ->
        if request.channel == CaseMapping.normalize(name) do
          reply_kick_request(state, request, frame["code"])
          {:reply, :ok, %{state | kick_pending: Map.delete(state.kick_pending, frame["id"])}}
        else
          {:reply, {:error, :invalid_kick_result}, state}
        end

      _ ->
        {:reply, {:error, :invalid_kick_result}, state}
    end
  end

  defp route_kick_result(state, peer_id, frame) do
    forward_mutation_frame(state, peer_id, frame)
    {:reply, :ok, state}
  end

  defp route_invite_request(%{id: id} = state, _peer_id, %{"to_origin" => id} = frame) do
    case InviteReplay.check(state.replays.invite, frame) do
      {:new, replay} ->
        key = CaseMapping.normalize(frame["channel"])

        decision =
          case state.channel_view[key] do
            %ChannelView{} = view when not is_nil(state.projector) ->
              InviteMutation.apply_remote(InviteMutation.from_frame(frame), state.replica, view, state.projector)

            _ ->
              {:error, :stale_channel}
          end

        code = InviteMutation.result_code(decision)
        away = InviteMutation.result_away(decision)
        updated = %{state | replays: %{state.replays | invite: InviteReplay.remember(replay, frame, code, away)}}
        send_invite_result(updated, frame, code, away)
        {:reply, :ok, updated}

      {:duplicate, %InviteReplayEntry{code: code, away: away}, replay} ->
        updated = %{state | replays: %{state.replays | invite: replay}}
        send_invite_result(updated, frame, code, away)
        {:reply, :ok, updated}

      {:conflict, replay} ->
        {:reply, {:error, :reused_message_id}, %{state | replays: %{state.replays | invite: replay}}}
    end
  end

  defp route_invite_request(state, peer_id, frame) do
    case Replica.get_by_uid(state.replica, frame["origin"], frame["from_uid"]) do
      {:ok, _sender} ->
        forward_mutation_frame(state, peer_id, frame)
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :unknown_sender}, state}
    end
  end

  defp send_invite_result(state, frame, code, away) do
    result = %{
      "type" => "invite_result",
      "origin" => state.id,
      "epoch" => state.local_epoch,
      "to_origin" => frame["origin"],
      "to_uid" => frame["from_uid"],
      "target_uid" => frame["to_uid"],
      "channel" => frame["channel"],
      "id" => frame["id"],
      "code" => code,
      "away" => away,
      "ttl" => 64
    }

    if Frame.validate(result) == :ok, do: forward_mutation_frame(state, nil, result)
  end

  defp route_invite_result(
         %{id: id} = state,
         _peer_id,
         %{
           "to_origin" => id,
           "to_uid" => uid,
           "origin" => authority,
           "epoch" => epoch,
           "target_uid" => target_uid,
           "channel" => name
         } = frame
       ) do
    case Map.get(state.invite_pending, frame["id"]) do
      nil ->
        {:reply, :ok, state}

      %InvitePending{uid: ^uid, authority: ^authority, authority_epoch: ^epoch, target_uid: ^target_uid} = request ->
        finish_invite_result(state, request, frame, name)

      _ ->
        {:reply, {:error, :invalid_invite_result}, state}
    end
  end

  defp route_invite_result(state, peer_id, frame) do
    forward_mutation_frame(state, peer_id, frame)
    {:reply, :ok, state}
  end

  defp finish_invite_result(state, request, frame, name) do
    if request.channel == CaseMapping.normalize(name) do
      reply_invite_request(state, request, frame["code"], frame["away"])
      if frame["code"] == "ok", do: announce_invite_notice(state, request, frame["id"])
      {:reply, :ok, %{state | invite_pending: Map.delete(state.invite_pending, frame["id"])}}
    else
      {:reply, {:error, :invalid_invite_result}, state}
    end
  end

  defp announce_invite_notice(state, %InvitePending{} = request, id) do
    notice = %InviteNotice{
      origin: state.id,
      epoch: state.local_epoch,
      id: id,
      uid: request.uid,
      sender_mask: request.sender_mask,
      sender_account: request.sender_account,
      target_origin: request.authority,
      target_uid: request.target_uid,
      target_nick: request.target_nick,
      channel: request.channel,
      channel_ref: request.channel_ref,
      ttl: 64
    }

    enqueue_channel_if_valid(state, InviteMutation.notice_frame(notice))
  end

  defp forward_mutation_frame(state, peer_id, %{"ttl" => ttl} = frame) do
    case state.routes[frame["to_origin"]] do
      %{via: via} when via != peer_id and ttl > 1 ->
        case Map.fetch(state.links, via) do
          {:ok, pid} -> enqueue_link(pid, {:link_frame, %{frame | "ttl" => ttl - 1}})
          :error -> :ok
        end

      _ ->
        :ok
    end
  end

  defp forward_direct_message(state, via, frame) do
    if frame["ttl"] > 1 do
      case Map.fetch(state.links, via) do
        {:ok, pid} -> enqueue_link(pid, {:link_frame, %{frame | "ttl" => frame["ttl"] - 1}})
        :error -> :ok
      end
    end
  end

  defp forward_channel_message(state, peer_id, frame) do
    if frame["ttl"] > 1 do
      Enum.each(state.links, &forward_channel_to_peer(&1, peer_id, frame))
    end
  end

  defp forward_channel_to_peer({peer_id, _pid}, peer_id, _frame), do: :ok

  defp forward_channel_to_peer({_destination, pid}, _peer_id, frame) do
    enqueue_link(pid, {:link_frame, %{frame | "ttl" => frame["ttl"] - 1}})
  end

  defp dispatch_accepted_channel(state, outbound, sender_uid, delivery) do
    tags =
      if "message-tags" in delivery.sender.capabilities,
        do: Map.filter(outbound.tags, fn {key, _value} -> String.starts_with?(key, "+") end),
        else: %{}

    frame = %{
      "type" => "channel_message",
      "origin" => state.id,
      "epoch" => state.local_epoch,
      "from_uid" => sender_uid,
      "channel" => outbound.channel,
      "channel_creator" => delivery.identity.creator,
      "channel_created_at" => delivery.identity.created_at,
      "target" => outbound.target,
      "command" => outbound.command,
      "text" => outbound.text,
      "tags" => tags,
      "ttl" => 64,
      "id" => UserPayload.new_uid()
    }

    if Frame.validate(frame) == :ok do
      dispatch_local_channel(outbound, delivery)
      enqueue_channel_if_valid(state, frame)
    else
      ChannelMessage.reply_local_error(outbound, delivery.sender, :network_directory_unavailable)
    end
  end

  defp dispatch_local_channel(%ChannelOutbound{remote_only: true}, _delivery), do: :ok

  defp dispatch_local_channel(outbound, delivery) do
    %Message{command: outbound.command, params: [outbound.target], trailing: outbound.text, tags: outbound.tags}
    |> Dispatcher.broadcast_with_echo(delivery.sender, delivery.recipients)
  end

  defp enqueue_channel_if_valid(state, frame) do
    if Frame.validate(frame) == :ok,
      do: Enum.each(state.links, fn {_peer_id, pid} -> enqueue_link(pid, {:link_frame, frame}) end)
  end

  defp reply_channel_unavailable(outbound), do: reply_channel_error(outbound, :network_directory_unavailable)

  defp reply_channel_error(%ChannelOutbound{} = outbound, reason) do
    case Memento.transaction!(fn -> Users.get_by_pid(outbound.sender_pid) end) do
      {:ok, %{registered: true} = user} -> ChannelMessage.reply_local_error(outbound, user, reason)
      _ -> :ok
    end
  end

  defp validate_route_path(local_id, peer_id, path) do
    cond do
      List.last(path) != peer_id -> {:error, :wrong_route_sender}
      local_id in path or length(path) >= 64 -> {:error, :topology_cycle}
      true -> :ok
    end
  end

  defp route_existing_action(current, peer_id, frame, local_id) do
    cond do
      current != nil and current.via != peer_id -> {:error, :duplicate_route}
      current != nil and current.epoch == frame["epoch"] and current.path == frame["path"] ++ [local_id] -> :same
      current != nil and current.epoch == frame["epoch"] -> {:error, :route_changed}
      true -> :replace
    end
  end

  defp apply_remote_data(state, peer_id, frame) do
    case Replica.apply(state.replica, frame) do
      {:ok, replica} ->
        updated = %{state | replica: replica}
        forward_remote_data(updated, peer_id, frame, state.replica)
        {:reply, :ok, updated}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp forward_remote_data(state, peer_id, %{"type" => "snapshot_end", "origin" => origin}, _prior_replica) do
    Enum.each(state.links, fn {destination, pid} ->
      if destination != peer_id, do: send_committed_origin(destination, pid, state, origin)
    end)
  end

  defp forward_remote_data(state, peer_id, %{"type" => "delta_end", "origin" => origin} = frame, prior_replica) do
    delta = Map.fetch!(prior_replica.deltas, origin)

    begin_frame = %{
      "type" => "delta_begin",
      "origin" => origin,
      "epoch" => frame["epoch"],
      "sequence" => frame["sequence"],
      "count" => delta.expected
    }

    frames = [begin_frame | Enum.reverse(delta.entries)] ++ [frame]
    route = Map.fetch!(state.routes, origin)

    Enum.each(state.links, fn {destination, pid} ->
      if destination != peer_id and destination not in route.path, do: enqueue_link(pid, {:link_delta, frames})
    end)
  end

  defp forward_remote_data(state, peer_id, %{"type" => type} = frame, _prior_replica)
       when type in ["user_upsert", "user_remove"] do
    route = Map.fetch!(state.routes, frame["origin"])

    Enum.each(state.links, fn {destination, pid} ->
      if destination != peer_id and destination not in route.path, do: enqueue_link(pid, {:link_frame, frame})
    end)
  end

  defp forward_remote_data(_state, _peer_id, _frame, _prior_replica), do: :ok

  defp index_local_channels(channels) do
    Map.new(channels, &{CaseMapping.normalize(&1["name"]), &1})
  end

  defp refresh_channel_views(state) do
    selected = ChannelAuthority.select(state.id, state.local_channels, state.replica.channels)
    view = ChannelView.build(selected, state.replica)
    ChannelDirectory.sync(state.indexes.channel_directory, state.channel_view, view)
    %{state | channel_authorities: selected, channel_view: view}
  end

  defp maybe_refresh_channel_views(previous, updated) do
    if previous.local_channels == updated.local_channels and previous.replica.users == updated.replica.users and
         previous.replica.channels == updated.replica.channels and
         previous.replica.members == updated.replica.members and previous.replica.lists == updated.replica.lists and
         previous.replica.invites == updated.replica.invites,
       do: updated,
       else: refresh_channel_views(updated)
  end

  defp maybe_publish_network_stats(%{"type" => type}, state)
       when type in ["route_up", "route_down", "snapshot_end", "delta_end", "user_upsert", "user_remove"] do
    NetworkStats.publish(state.indexes.network_stats, state.replica, state.routes, state.links, state.channel_view)
  end

  defp maybe_publish_network_stats(_frame, _state), do: :ok

  defp maybe_deliver_channel_delta(%{"type" => "delta_end", "origin" => origin}, previous, current, prior_memberships) do
    ChannelEvents.deliver_delta(
      previous.replica,
      current.replica,
      origin,
      previous.channel_view,
      current.channel_view,
      prior_memberships
    )
  end

  defp maybe_deliver_channel_delta(
         %{"type" => "snapshot_end", "origin" => origin},
         previous,
         current,
         prior_memberships
       ) do
    ChannelEvents.deliver_snapshot(
      previous.replica,
      current.replica,
      origin,
      previous.channel_view,
      current.channel_view,
      prior_memberships
    )
  end

  defp maybe_deliver_channel_delta(%{"type" => type}, previous, current, _prior_memberships)
       when type in ["route_up", "route_down"] do
    ChannelEvents.deliver_route_lists(previous.channel_view, current.channel_view)
  end

  defp maybe_deliver_channel_delta(_frame, _previous, _current, _prior_memberships), do: :ok

  defp maybe_deliver_departures(%{"type" => type}, previous, current)
       when type in ["snapshot_end", "route_up", "route_down"] do
    reason = if type == "snapshot_end", do: "Remote state resynchronized", else: "Server link lost"
    UserEvents.deliver_departures(previous.replica, current.replica, previous.channel_view, reason)
  end

  defp maybe_deliver_departures(_frame, _previous, _current), do: :ok

  defp initial_local_state(nil), do: {UserPayload.new_uid(), 0, %{}}

  defp initial_local_state(projector) do
    :ok = Projector.subscribe(projector, self())
    snapshot = Projector.snapshot(projector)
    {snapshot.epoch, snapshot.cursor, index_local_channels(snapshot.channels)}
  end

  defp apply_local_channel_delta(channels, frames) do
    Enum.reduce(frames, channels, fn
      %{"type" => "delta_entry", "field" => "channel", "action" => "remove", "entry" => entry}, acc ->
        Map.delete(acc, CaseMapping.normalize(entry["name"]))

      %{"type" => "delta_entry", "field" => "channel", "action" => "upsert", "entry" => entry}, acc ->
        Map.put(acc, CaseMapping.normalize(entry["name"]), entry)

      _frame, acc ->
        acc
    end)
  end

  defp local_snapshot(%{projector: nil} = state),
    do: %Snapshot{origin: state.id, epoch: state.local_epoch, cursor: 0, users: []}

  defp local_snapshot(state), do: Projector.snapshot(state.projector)

  defp route_up_frame(origin, epoch, path) do
    %{"type" => "route_up", "origin" => origin, "epoch" => epoch, "path" => path}
  end

  defp send_committed_routes(destination, pid, state) do
    Enum.each(state.routes, fn {origin, _route} -> send_committed_origin(destination, pid, state, origin) end)
  end

  defp send_committed_origin(destination, pid, state, origin) do
    with {:ok, %{epoch: epoch, cursor: cursor}} <- Replica.origin_state(state.replica, origin),
         %{path: path} <- Map.fetch!(state.routes, origin),
         false <- destination in path do
      enqueue_link(pid, {:link_frame, route_up_frame(origin, epoch, path)})

      enqueue_link(
        pid,
        {:link_snapshot,
         %Snapshot{
           origin: origin,
           epoch: epoch,
           cursor: cursor,
           users: Replica.users_from(state.replica, origin),
           channels: Replica.channels_from(state.replica, origin),
           members: Replica.members_from(state.replica, origin),
           lists: Replica.lists_from(state.replica, origin),
           invites: Replica.invites_from(state.replica, origin)
         }}
      )
    else
      _ -> :ok
    end
  end

  defp register_snapshot(state, id, pid, snapshot) do
    state = release_pending(state, pid)
    ref = Process.monitor(pid)
    enqueue_link(pid, {:link_frame, route_up_frame(state.id, snapshot.epoch, [state.id])})
    enqueue_link(pid, {:link_snapshot, snapshot})
    send_committed_routes(id, pid, state)

    new_state = %{
      state
      | links: Map.put(state.links, id, pid),
        link_cursors: Map.put(state.link_cursors, id, snapshot.cursor),
        link_refs: Map.put(state.link_refs, ref, id),
        local_cursor: snapshot.cursor,
        local_channels: index_local_channels(snapshot.channels)
    }

    Logger.info("server link established with #{id}")
    updated = maybe_refresh_channel_views(state, new_state)

    NetworkStats.publish(
      updated.indexes.network_stats,
      updated.replica,
      updated.routes,
      updated.links,
      updated.channel_view
    )

    {:reply, :ok, updated}
  end

  defp drop_routes_via(state, peer_id) do
    origins = for {origin, %{via: ^peer_id}} <- state.routes, do: origin
    drop_routes(state, origins)
  end

  defp drop_route_tree(state, origin) do
    origins = for {candidate, %{path: path}} <- state.routes, origin in path, do: candidate
    drop_routes(state, origins)
  end

  defp drop_routes(state, origins) do
    removed =
      for origin <- origins,
          {:ok, _committed} <- [Replica.origin_state(state.replica, origin)],
          do: {origin, Map.fetch!(state.routes, origin)}

    routes = Enum.reduce(origins, state.routes, &Map.delete(&2, &1))
    replica = Enum.reduce(origins, state.replica, &Replica.drop_origin(&2, &1))
    {routes, replica, removed}
  end

  defp notify_route_down(state, removed, source_peer_id) do
    origins = MapSet.new(removed, &elem(&1, 0))

    roots =
      Enum.reject(removed, fn {origin, route} ->
        Enum.any?(route.path, &(&1 != origin and MapSet.member?(origins, &1)))
      end)

    for {origin, route} <- roots, {destination, pid} <- state.links, destination != source_peer_id do
      enqueue_link(pid, {:link_frame, %{"type" => "route_down", "origin" => origin, "epoch" => route.epoch}})
    end
  end

  defp maybe_reconcile_nicks(%{"type" => "snapshot_end"}, state),
    do: NickReconciler.reconcile(state.replica, state.id)

  defp maybe_reconcile_nicks(%{"type" => "user_upsert", "user" => user}, state),
    do: NickReconciler.reconcile(state.replica, state.id, [user["nick"]])

  defp maybe_reconcile_nicks(_frame, _state), do: :ok

  defp maybe_reconcile_local_nick(%{"type" => "user_upsert", "user" => user}, state),
    do: NickReconciler.reconcile(state.replica, state.id, [user["nick"]])

  defp maybe_reconcile_local_nick(_frame, _state), do: :ok

  defp enqueue_link(pid, message) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, count} when count < @max_outbound_messages ->
        send(pid, message)
        :ok

      {:message_queue_len, _count} ->
        Logger.warning("server link output queue exceeded its limit")
        Process.exit(pid, :kill)
        {:error, :backpressure}

      nil ->
        {:error, :closed}
    end
  end

  defp release_pending(state, pid) do
    case Map.pop(state.pending, pid) do
      {nil, _pending} ->
        state

      {ref, pending} ->
        Process.demonitor(ref, [:flush])
        %{state | pending: pending, pending_refs: Map.delete(state.pending_refs, ref)}
    end
  end

  defp accept_loop(listener, hub, id, network) do
    case :ssl.transport_accept(listener) do
      {:ok, socket} ->
        accept_socket(socket, hub, id, network)
        accept_loop(listener, hub, id, network)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.error("server link accept failed: #{inspect(reason)}")
        exit({:server_link_accept_failed, reason})
    end
  end

  defp accept_socket(socket, hub, id, network) do
    worker = spawn(fn -> Peer.run_inbound(hub, socket, id, network) end)

    case GenServer.call(hub, {:reserve_inbound, worker}) do
      :ok -> transfer_socket(socket, worker)
      {:error, :capacity} -> abort_socket(socket, worker)
    end
  end

  defp transfer_socket(socket, worker) do
    case :ssl.controlling_process(socket, worker) do
      :ok -> send(worker, :socket_ready)
      {:error, _reason} -> abort_socket(socket, worker)
    end
  end

  defp abort_socket(socket, worker) do
    :ssl.close(socket)
    send(worker, :abort)
  end
end
