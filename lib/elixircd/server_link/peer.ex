defmodule ElixIRCd.ServerLink.Peer do
  @moduledoc "A single authenticated, bounded, direct server-link TLS session."

  require Logger

  alias ElixIRCd.ServerLink.Frame
  alias ElixIRCd.ServerLink.Snapshot

  @handshake_timeout 5_000
  @idle_timeout 30_000
  @pong_timeout 10_000
  @topology_rejections %{
    "topology_cycle" => :topology_cycle,
    "duplicate_route" => :duplicate_route,
    "route_changed" => :route_changed,
    "wrong_route_sender" => :wrong_route_sender
  }

  @doc "Builds strict mutual-TLS options for the server-link listener."
  @spec listen_options(keyword()) :: keyword()
  def listen_options(config) do
    [
      ip: config[:bind_ip],
      certfile: String.to_charlist(config[:certfile]),
      keyfile: String.to_charlist(config[:keyfile]),
      cacertfile: String.to_charlist(config[:cacertfile]),
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      versions: [:"tlsv1.3"],
      active: false,
      mode: :binary,
      packet: 0,
      reuseaddr: true
    ]
  end

  @doc "Completes TLS and protocol authentication for an accepted socket."
  @spec run_inbound(pid(), :ssl.sslsocket(), String.t(), String.t()) :: :ok
  def run_inbound(hub, transport_socket, local_id, network) do
    receive do
      :abort ->
        :ok

      :socket_ready ->
        case :ssl.handshake(transport_socket, @handshake_timeout) do
          {:ok, socket} ->
            run_connected(hub, socket, :inbound, nil, local_id, network)

          {:error, reason} ->
            Logger.warning("server link TLS handshake failed: #{inspect(reason)}")
            :ssl.close(transport_socket)
        end
    after
      @handshake_timeout -> :ssl.close(transport_socket)
    end
  end

  @doc "Dials and authenticates one configured peer."
  @spec run_outbound(pid(), String.t(), String.t(), keyword(), map()) :: :ok
  def run_outbound(hub, local_id, network, listen, peer) do
    options =
      listen
      |> listen_options()
      |> Keyword.drop([:ip, :fail_if_no_peer_cert, :reuseaddr])
      |> Keyword.put(:server_name_indication, :disable)

    case :ssl.connect(String.to_charlist(peer.host), peer.port, options, @handshake_timeout) do
      {:ok, socket} -> run_connected(hub, socket, :outbound, peer, local_id, network)
      {:error, reason} -> Logger.warning("server link dial to #{peer.id} failed: #{inspect(reason)}")
    end
  end

  defp run_connected(hub, socket, direction, configured_peer, local_id, network) do
    hub_ref = Process.monitor(hub)

    result =
      with :ok <- Frame.send(socket, Frame.hello(local_id, network)),
           {:ok, %{"type" => "hello", "id" => remote_id} = hello} <- Frame.recv(socket, @handshake_timeout),
           {:ok, peer} <- resolve_peer(hub, remote_id, configured_peer),
           :ok <- validate_hello(hello, local_id, network, peer),
           :ok <- validate_certificate(socket, peer.certificate_sha256),
           :ok <- GenServer.call(hub, {:register, peer.id, direction, self()}, @handshake_timeout),
           :ok <- :ssl.setopts(socket, active: :once) do
        loop(socket, hub, peer.id, hub_ref, <<>>, nil, 0, deadline(@idle_timeout))
      end

    if result != :ok, do: Logger.warning("server link rejected: #{inspect(result)}")
    :ssl.close(socket)
    :ok
  end

  defp resolve_peer(hub, remote_id, nil), do: GenServer.call(hub, {:peer, remote_id}, @handshake_timeout)
  defp resolve_peer(_hub, remote_id, %{id: remote_id} = peer), do: {:ok, peer}
  defp resolve_peer(_hub, _remote_id, _peer), do: {:error, :wrong_peer_id}

  defp validate_hello(hello, local_id, network, peer) do
    case_mapping = Application.fetch_env!(:elixircd, :settings)[:case_mapping] |> Atom.to_string()

    cond do
      hello["id"] == local_id -> {:error, :self_link}
      hello["id"] != peer.id -> {:error, :wrong_peer_id}
      hello["network"] != network -> {:error, :wrong_network}
      hello["case_mapping"] != case_mapping -> {:error, :wrong_case_mapping}
      true -> :ok
    end
  end

  defp validate_certificate(socket, expected_hex) do
    with {:ok, der} <- :ssl.peercert(socket) do
      actual = der |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
      if actual == String.downcase(expected_hex), do: :ok, else: {:error, :certificate_pin_mismatch}
    end
  end

  defp loop(socket, hub, peer_id, hub_ref, buffer, awaiting_pong, sequence, expiry) do
    remaining = max(0, expiry - System.monotonic_time(:millisecond))

    receive do
      {:ssl, ^socket, bytes} ->
        with {:ok, rest, next_awaiting} <- consume(socket, hub, peer_id, buffer <> bytes, awaiting_pong),
             :ok <- :ssl.setopts(socket, active: :once) do
          next_expiry = if next_awaiting, do: expiry, else: deadline(@idle_timeout)
          loop(socket, hub, peer_id, hub_ref, rest, next_awaiting, sequence, next_expiry)
        end

      {kind, payload} when kind in [:link_snapshot, :link_delta, :link_frame] ->
        case send_link_payload(socket, kind, payload) do
          :ok -> loop(socket, hub, peer_id, hub_ref, buffer, awaiting_pong, sequence, expiry)
          error -> error
        end

      {:DOWN, ^hub_ref, :process, _hub, _reason} ->
        :ok

      {:ssl_closed, ^socket} ->
        :ok

      {:ssl_error, ^socket, reason} ->
        {:error, reason}
    after
      remaining ->
        if awaiting_pong do
          {:error, :pong_timeout}
        else
          next = sequence + 1

          case Frame.send(socket, %{"type" => "ping", "sequence" => next}) do
            :ok -> loop(socket, hub, peer_id, hub_ref, buffer, next, next, deadline(@pong_timeout))
            error -> error
          end
        end
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp send_link_payload(socket, :link_snapshot, snapshot), do: send_snapshot(socket, snapshot)
  defp send_link_payload(socket, :link_delta, frames), do: send_frames(socket, frames)
  defp send_link_payload(socket, :link_frame, frame), do: Frame.send(socket, frame)

  defp consume(socket, hub, peer_id, buffer, awaiting_pong) do
    case Frame.decode_one(buffer) do
      :more ->
        {:ok, buffer, awaiting_pong}

      {:error, reason} ->
        {:error, reason}

      {:ok, %{"type" => "ping", "sequence" => sequence}, rest} ->
        with :ok <- Frame.send(socket, %{"type" => "pong", "sequence" => sequence}),
             do: consume(socket, hub, peer_id, rest, awaiting_pong)

      {:ok, %{"type" => "pong", "sequence" => sequence}, rest} when sequence == awaiting_pong ->
        consume(socket, hub, peer_id, rest, nil)

      {:ok, %{"type" => "reject", "code" => code}, _rest} ->
        :ok = GenServer.call(hub, {:peer_reject, peer_id, self(), Map.fetch!(@topology_rejections, code)})
        {:error, :topology_rejected}

      {:ok, %{"type" => type} = frame, rest}
      when type in [
             "route_up",
             "route_down",
             "snapshot_begin",
             "snapshot_user",
             "snapshot_channel",
             "snapshot_member",
             "snapshot_list",
             "snapshot_invite",
             "snapshot_end",
             "delta_begin",
             "delta_entry",
             "delta_end",
             "direct_message",
             "direct_result",
             "channel_message",
             "topic_request",
             "topic_result",
             "mode_request",
             "mode_result",
             "user_upsert",
             "user_remove"
           ] ->
        consume_data_frame(socket, hub, peer_id, frame, rest, awaiting_pong)

      {:ok, _frame, _rest} ->
        {:error, :unexpected_frame}
    end
  end

  defp consume_data_frame(socket, hub, peer_id, frame, rest, awaiting_pong) do
    case GenServer.call(hub, {:remote_frame, peer_id, self(), frame}, 30_000) do
      :ok ->
        consume(socket, hub, peer_id, rest, awaiting_pong)

      {:error, reason} = error ->
        reject_topology_error(socket, reason)
        error
    end
  end

  defp reject_topology_error(socket, reason) do
    if reason in Map.values(@topology_rejections),
      do: Frame.send(socket, %{"type" => "reject", "code" => Atom.to_string(reason)})
  end

  defp send_snapshot(socket, %Snapshot{} = snapshot) do
    origin = snapshot.origin
    epoch = snapshot.epoch
    channels = snapshot.channels
    members = snapshot.members
    lists = snapshot.lists
    invites = snapshot.invites

    begin_frame = %{
      "type" => "snapshot_begin",
      "origin" => origin,
      "epoch" => epoch,
      "cursor" => snapshot.cursor,
      "count" => length(snapshot.users),
      "channel_count" => length(channels),
      "member_count" => length(members),
      "list_count" => length(lists),
      "invite_count" => length(invites)
    }

    with :ok <- Frame.send(socket, begin_frame),
         :ok <- send_snapshot_entries(socket, origin, epoch, "user", snapshot.users),
         :ok <- send_snapshot_entries(socket, origin, epoch, "channel", channels),
         :ok <- send_snapshot_entries(socket, origin, epoch, "member", members),
         :ok <- send_snapshot_entries(socket, origin, epoch, "list", lists),
         :ok <- send_snapshot_entries(socket, origin, epoch, "invite", invites),
         do: Frame.send(socket, %{"type" => "snapshot_end", "origin" => origin, "epoch" => epoch})
  end

  defp send_snapshot_entries(socket, origin, epoch, field, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      frame = %{"type" => "snapshot_#{field}", "origin" => origin, "epoch" => epoch, field => entry}

      case Frame.send(socket, frame) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp send_frames(socket, frames) do
    Enum.reduce_while(frames, :ok, fn frame, :ok ->
      case Frame.send(socket, frame) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
