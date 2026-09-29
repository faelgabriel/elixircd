defmodule ElixIRCd.ServerLink.HubTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Commands.Nick
  alias ElixIRCd.Factory
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.Directory
  alias ElixIRCd.ServerLink.Frame
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.Projector
  alias ElixIRCd.ServerLink.Replica
  alias ElixIRCd.ServerLink.UserPayload
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping

  setup do
    directory = Path.join(System.tmp_dir!(), "elixircd-link-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    ca = certificate_authority(directory)
    server = certificate(directory, "server", "irc.test", ca)
    peer = certificate(directory, "peer", "a.example", ca)

    pin =
      peer.certfile
      |> File.read!()
      |> :public_key.pem_decode()
      |> hd()
      |> elem(1)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    config = [
      listen: [
        port: 0,
        bind_ip: {127, 0, 0, 1},
        certfile: server.certfile,
        keyfile: server.keyfile,
        cacertfile: ca.certfile
      ],
      peers: [%{id: "a.example", host: "127.0.0.1", port: 1, certificate_sha256: pin}]
    ]

    start_supervised!({Hub, config})
    {:ok, port} = Hub.listener_port()
    %{port: port, server: server, peer: peer, ca: ca, directory: directory}
  end

  test "mutual TLS and pinned identity establish one direct link", context do
    assert {:ok, client} = connect(context)
    assert {:ok, %{"type" => "hello", "id" => "irc.test"}} = Frame.recv(client, 5_000)
    assert :ok = Frame.send(client, Frame.hello("a.example", "Server Example"))
    assert eventually(fn -> Hub.status()["a.example"] == :connected end)
    :ssl.close(client)
    assert eventually(fn -> Hub.status()["a.example"] == :disconnected end)
  end

  test "wrong network is rejected without registering the peer", context do
    assert {:ok, client} = connect(context)
    assert {:ok, %{"type" => "hello"}} = Frame.recv(client, 5_000)
    assert :ok = Frame.send(client, Frame.hello("a.example", "Other Network"))
    assert {:error, :closed} = Frame.recv(client, 5_000)
    assert Hub.status()["a.example"] == :disconnected
    :ssl.close(client)
  end

  test "a different nickname case mapping is rejected", context do
    assert {:ok, client} = connect(context)
    assert {:ok, %{"type" => "hello"}} = Frame.recv(client, 5_000)
    hello = Map.put(Frame.hello("a.example", "Server Example"), "case_mapping", "ascii")
    assert :ok = Frame.send(client, hello)
    assert {:error, :closed} = Frame.recv(client, 5_000)
    assert Hub.status()["a.example"] == :disconnected
    :ssl.close(client)
  end

  test "a coordinator restart closes the old peer socket", context do
    assert {:ok, client} = connect(context)
    assert {:ok, %{"type" => "hello"}} = Frame.recv(client, 5_000)
    assert :ok = Frame.send(client, Frame.hello("a.example", "Server Example"))
    assert eventually(fn -> Hub.status()["a.example"] == :connected end)
    assert_receive_empty_snapshot(client)

    assert :ok = GenServer.stop(Hub, :normal)
    assert {:error, :closed} = Frame.recv(client, 5_000)
    :ssl.close(client)
  end

  test "a peer snapshot becomes visible only after its end frame and is removed on split", context do
    assert {:ok, client} = connect(context)
    assert {:ok, %{"type" => "hello"}} = Frame.recv(client, 5_000)
    assert :ok = Frame.send(client, Frame.hello("a.example", "Server Example"))
    assert_receive_empty_snapshot(client)
    assert eventually(fn -> Hub.status()["a.example"] == :connected end)

    epoch = UserPayload.new_uid()
    uid = UserPayload.new_uid()
    user = Factory.build(:user, nick: "RemoteAlice", hostname: "a.example")
    payload = UserPayload.from_local(user, uid)
    begin_frame = %{"type" => "snapshot_begin", "origin" => "a.example", "epoch" => epoch, "cursor" => 0, "count" => 1}
    item_frame = %{"type" => "snapshot_user", "origin" => "a.example", "epoch" => epoch, "user" => payload}
    end_frame = %{"type" => "snapshot_end", "origin" => "a.example", "epoch" => epoch}

    assert :ok =
             Frame.send(client, %{
               "type" => "route_up",
               "origin" => "a.example",
               "epoch" => epoch,
               "path" => ["a.example"]
             })

    assert :ok = Frame.send(client, begin_frame)
    assert :ok = Frame.send(client, item_frame)
    assert Hub.remote_users(Hub, "a.example") == []
    assert :ok = Frame.send(client, end_frame)
    assert eventually(fn -> Hub.remote_users(Hub, "a.example") == [payload] end)
    assert {:ok, %{origin: "a.example", uid: ^uid, user: ^payload}} = Directory.get_by_nick("remotealice")

    local = Factory.build(:user, nick: "LocalAlice")
    Memento.transaction!(fn -> Memento.Query.write(local) end)
    assert :ok = Memento.transaction!(fn -> Nick.handle(local, %Message{command: "NICK", params: ["RemoteAlice"]}) end)
    assert {:ok, %{nick: "LocalAlice"}} = Memento.transaction!(fn -> Users.get_by_pid(local.pid) end)

    :ssl.close(client)
    assert eventually(fn -> Hub.remote_users(Hub, "a.example") == [] end)
    assert :error = Directory.get_by_nick("RemoteAlice")
  end

  test "an older remote claim renames the local loser without closing the link", context do
    local = Factory.build(:user, nick: "SharedNick")
    Memento.transaction!(fn -> Memento.Query.write(local) end)

    assert {:ok, client} = connect(context)
    assert {:ok, %{"type" => "hello"}} = Frame.recv(client, 5_000)
    assert :ok = Frame.send(client, Frame.hello("a.example", "Server Example"))
    assert_receive_empty_snapshot(client)

    epoch = UserPayload.new_uid()

    payload =
      Factory.build(:user,
        nick: "SharedNick",
        hostname: "a.example",
        registered_at: DateTime.add(local.registered_at, -60)
      )
      |> UserPayload.from_local(UserPayload.new_uid())

    assert :ok =
             Frame.send(client, %{
               "type" => "route_up",
               "origin" => "a.example",
               "epoch" => epoch,
               "path" => ["a.example"]
             })

    assert :ok =
             Frame.send(client, %{
               "type" => "snapshot_begin",
               "origin" => "a.example",
               "epoch" => epoch,
               "cursor" => 0,
               "count" => 1
             })

    assert :ok =
             Frame.send(client, %{
               "type" => "snapshot_user",
               "origin" => "a.example",
               "epoch" => epoch,
               "user" => payload
             })

    assert :ok = Frame.send(client, %{"type" => "snapshot_end", "origin" => "a.example", "epoch" => epoch})
    assert eventually(fn -> Hub.remote_users(Hub, "a.example") == [payload] end)

    assert eventually(fn ->
             Memento.transaction!(fn ->
               match?({:ok, %{nick: nick}} when nick != "SharedNick", Users.get_by_pid(local.pid))
             end)
           end)

    assert Hub.status()["a.example"] == :connected
    assert {:ok, %{user: ^payload}} = Directory.get_by_nick("SharedNick")
    :ssl.close(client)
  end

  test "a route that loops through this server is rejected and suppresses reconnects", context do
    assert {:ok, client} = connect(context)
    assert {:ok, %{"type" => "hello"}} = Frame.recv(client, 5_000)
    assert :ok = Frame.send(client, Frame.hello("a.example", "Server Example"))
    assert_receive_empty_snapshot(client)

    assert :ok =
             Frame.send(client, %{
               "type" => "route_up",
               "origin" => "irc.test",
               "epoch" => UserPayload.new_uid(),
               "path" => ["irc.test", "a.example"]
             })

    assert {:ok, %{"type" => "reject", "code" => "topology_cycle"}} = Frame.recv(client, 5_000)
    assert {:error, :closed} = Frame.recv(client, 5_000)
    assert eventually(fn -> Hub.status()["a.example"] == :disconnected end)
    assert Hub.suppressed_peers() == ["a.example"]
    :ssl.close(client)
  end

  test "one peer cannot announce more remote origins than the route budget", context do
    assert {:ok, client} = connect(context)
    assert {:ok, %{"type" => "hello"}} = Frame.recv(client, 5_000)
    assert :ok = Frame.send(client, Frame.hello("a.example", "Server Example"))
    assert_receive_empty_snapshot(client)
    :sys.replace_state(Hub, &Map.put(&1, :max_remote_origins, 1))

    assert :ok =
             Frame.send(client, %{
               "type" => "route_up",
               "origin" => "a.example",
               "epoch" => UserPayload.new_uid(),
               "path" => ["a.example"]
             })

    assert eventually(fn -> Map.has_key?(Hub.routes(), "a.example") end)

    assert :ok =
             Frame.send(client, %{
               "type" => "route_up",
               "origin" => "b.example",
               "epoch" => UserPayload.new_uid(),
               "path" => ["b.example", "a.example"]
             })

    assert {:error, :closed} = Frame.recv(client, 5_000)
    assert eventually(fn -> Hub.status()["a.example"] == :disconnected end)
    assert Hub.suppressed_peers() == []
    :ssl.close(client)
  end

  test "an authenticated peer cannot send as an unannounced user", context do
    assert {:ok, client} = connect(context)
    assert {:ok, %{"type" => "hello"}} = Frame.recv(client, 5_000)
    assert :ok = Frame.send(client, Frame.hello("a.example", "Server Example"))
    assert_receive_empty_snapshot(client)

    epoch = UserPayload.new_uid()

    assert :ok =
             Frame.send(client, %{
               "type" => "route_up",
               "origin" => "a.example",
               "epoch" => epoch,
               "path" => ["a.example"]
             })

    assert :ok =
             Frame.send(client, %{
               "type" => "snapshot_begin",
               "origin" => "a.example",
               "epoch" => epoch,
               "cursor" => 0,
               "count" => 0
             })

    assert :ok = Frame.send(client, %{"type" => "snapshot_end", "origin" => "a.example", "epoch" => epoch})

    assert :ok =
             Frame.send(client, %{
               "type" => "direct_message",
               "origin" => "a.example",
               "epoch" => epoch,
               "from_uid" => UserPayload.new_uid(),
               "to_origin" => "irc.test",
               "to_uid" => UserPayload.new_uid(),
               "command" => "PRIVMSG",
               "text" => "forged",
               "tags" => %{},
               "ttl" => 64,
               "id" => UserPayload.new_uid(),
               "sent_at" => DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
             })

    assert {:error, :closed} = Frame.recv(client, 5_000)
    assert eventually(fn -> Hub.status()["a.example"] == :disconnected end)
    :ssl.close(client)
  end

  test "a peer topology rejection suppresses reconnection", context do
    assert {:ok, client} = connect(context)
    assert {:ok, %{"type" => "hello"}} = Frame.recv(client, 5_000)
    assert :ok = Frame.send(client, Frame.hello("a.example", "Server Example"))
    assert_receive_empty_snapshot(client)

    assert :ok = Frame.send(client, %{"type" => "reject", "code" => "duplicate_route"})
    assert {:error, :closed} = Frame.recv(client, 5_000)
    assert eventually(fn -> Hub.status()["a.example"] == :disconnected end)
    assert Hub.suppressed_peers() == ["a.example"]
    :ssl.close(client)
  end

  test "committed local users are sent as snapshot and ordered live events", context do
    local_user = Factory.build(:user, nick: "LocalAlice", hostname: "irc.test")
    Memento.transaction!(fn -> Memento.Query.write(local_user) end)

    projector = start_supervised!({Projector, [name: nil, id: "irc.test"]})
    %{server: server, peer: peer, ca: ca} = context

    config = [
      name: nil,
      id: "irc.test",
      network: "Server Example",
      projector: projector,
      listen: [
        port: 0,
        bind_ip: {127, 0, 0, 1},
        certfile: server.certfile,
        keyfile: server.keyfile,
        cacertfile: ca.certfile
      ],
      peers: [%{id: "a.example", host: "127.0.0.1", port: 1, certificate_sha256: pin(peer)}]
    ]

    hub = start_supervised!(Supervisor.child_spec({Hub, config}, id: :projected_hub))
    {:ok, port} = Hub.listener_port(hub)
    assert {:ok, client} = connect(%{context | port: port})
    assert {:ok, %{"type" => "hello"}} = Frame.recv(client, 5_000)
    assert :ok = Frame.send(client, Frame.hello("a.example", "Server Example"))

    assert {:ok, %{"type" => "route_up", "origin" => "irc.test", "path" => ["irc.test"]}} =
             Frame.recv(client, 5_000)

    assert {:ok, %{"type" => "snapshot_begin", "count" => 1, "cursor" => 0, "epoch" => epoch}} =
             Frame.recv(client, 5_000)

    assert {:ok, %{"type" => "snapshot_user", "user" => payload}} = Frame.recv(client, 5_000)
    assert payload["nick"] == "LocalAlice"
    refute Map.has_key?(payload, "pid")
    assert {:ok, %{"type" => "snapshot_end"}} = Frame.recv(client, 5_000)

    send(
      hub,
      {:server_link_local_event,
       %{"type" => "user_upsert", "origin" => "irc.test", "epoch" => epoch, "sequence" => 0, "user" => payload}}
    )

    Hub.status(hub)

    renamed = %{local_user | nick: "LocalBob", nick_key: CaseMapping.normalize("LocalBob")}
    Memento.transaction!(fn -> Memento.Query.write(renamed) end)
    assert {:ok, %{"type" => "user_upsert", "sequence" => 1, "user" => changed}} = Frame.recv(client, 5_000)
    assert changed["uid"] == payload["uid"]
    assert changed["nick"] == "LocalBob"

    Memento.transaction!(fn -> Memento.Query.delete(User, local_user.pid) end)
    assert {:ok, %{"type" => "user_remove", "sequence" => 2, "uid" => uid}} = Frame.recv(client, 5_000)
    assert uid == payload["uid"]
    :ssl.close(client)
  end

  test "certificate pin mismatch is rejected after mutual TLS", context do
    :sys.replace_state(Hub, fn state ->
      peer = state.peers["a.example"]
      %{state | peers: Map.put(state.peers, "a.example", %{peer | certificate_sha256: String.duplicate("0", 64)})}
    end)

    assert {:ok, client} = connect(context)
    assert {:ok, %{"type" => "hello"}} = Frame.recv(client, 5_000)
    assert :ok = Frame.send(client, Frame.hello("a.example", "Server Example"))
    assert {:error, :closed} = Frame.recv(client, 5_000)
    assert Hub.status()["a.example"] == :disconnected
    :ssl.close(client)
  end

  test "two coordinators establish one socket through the network", context do
    %{ca: ca, server: server, peer: peer} = context

    accepting = [
      name: nil,
      id: "irc.test",
      network: "Server Example",
      listen: [
        port: 0,
        bind_ip: {127, 0, 0, 1},
        certfile: server.certfile,
        keyfile: server.keyfile,
        cacertfile: ca.certfile
      ],
      peers: [%{id: "a.example", host: "127.0.0.1", port: 1, certificate_sha256: pin(peer)}]
    ]

    b = start_supervised!(Supervisor.child_spec({Hub, accepting}, id: :accepting_hub))
    {:ok, port} = Hub.listener_port(b)

    dialing = [
      name: nil,
      id: "a.example",
      network: "Server Example",
      listen: [
        port: 0,
        bind_ip: {127, 0, 0, 1},
        certfile: peer.certfile,
        keyfile: peer.keyfile,
        cacertfile: ca.certfile
      ],
      peers: [%{id: "irc.test", host: "127.0.0.1", port: port, certificate_sha256: pin(server)}]
    ]

    a = start_supervised!(Supervisor.child_spec({Hub, dialing}, id: :dialing_hub))
    assert eventually(fn -> Hub.status(a)["irc.test"] == :connected and Hub.status(b)["a.example"] == :connected end)
  end

  test "three servers route user changes across an intermediate server", context do
    %{ca: ca, server: middle_cert, peer: first_cert, directory: directory} = context
    last_cert = certificate(directory, "last", "z.example", ca)

    last_config = [
      name: nil,
      id: "z.example",
      network: "Server Example",
      listen: link_listener(last_cert, ca),
      peers: [%{id: "irc.test", host: "127.0.0.1", port: 1, certificate_sha256: pin(middle_cert)}]
    ]

    last = start_supervised!(Supervisor.child_spec({Hub, last_config}, id: :last_hub))
    {:ok, last_port} = Hub.listener_port(last)

    middle_config = [
      name: nil,
      id: "irc.test",
      network: "Server Example",
      listen: link_listener(middle_cert, ca),
      peers: [
        %{id: "a.example", host: "127.0.0.1", port: 1, certificate_sha256: pin(first_cert)},
        %{id: "z.example", host: "127.0.0.1", port: last_port, certificate_sha256: pin(last_cert)}
      ]
    ]

    middle = start_supervised!(Supervisor.child_spec({Hub, middle_config}, id: :middle_hub))
    {:ok, middle_port} = Hub.listener_port(middle)

    first_config = [
      name: nil,
      id: "a.example",
      network: "Server Example",
      listen: link_listener(first_cert, ca),
      peers: [%{id: "irc.test", host: "127.0.0.1", port: middle_port, certificate_sha256: pin(middle_cert)}]
    ]

    first = start_supervised!(Supervisor.child_spec({Hub, first_config}, id: :first_hub))

    assert eventually(fn ->
             Hub.routes(first)["z.example"] != nil and
               Hub.routes(last)["a.example"] != nil and
               match?({:ok, _}, Replica.origin_state(:sys.get_state(last).replica, "a.example"))
           end)

    epoch = :sys.get_state(first).local_epoch

    payload =
      Factory.build(:user, nick: "AcrossThree", hostname: "a.example")
      |> UserPayload.from_local(UserPayload.new_uid())

    upsert = %{"type" => "user_upsert", "origin" => "a.example", "epoch" => epoch, "sequence" => 1, "user" => payload}
    send(first, {:server_link_local_event, upsert})
    assert eventually(fn -> Hub.remote_users(last, "a.example") == [payload] end)

    remove = %{
      "type" => "user_remove",
      "origin" => "a.example",
      "epoch" => epoch,
      "sequence" => 2,
      "uid" => payload["uid"]
    }

    send(first, {:server_link_local_event, remove})
    assert eventually(fn -> Hub.remote_users(last, "a.example") == [] end)

    channel = Factory.build(:channel, name: "#across") |> ChannelPayload.from_local()

    delta = [
      %{"type" => "delta_begin", "origin" => "a.example", "epoch" => epoch, "sequence" => 3, "count" => 1},
      %{
        "type" => "delta_entry",
        "origin" => "a.example",
        "epoch" => epoch,
        "field" => "channel",
        "action" => "upsert",
        "entry" => channel
      },
      %{"type" => "delta_end", "origin" => "a.example", "epoch" => epoch, "sequence" => 3}
    ]

    send(first, {:server_link_local_delta, delta})

    assert eventually(fn -> Hub.remote_channels(last, "a.example") == [channel] end)

    first_link = :sys.get_state(middle).links["a.example"]
    Process.exit(first_link, :kill)
    assert eventually(fn -> Hub.routes(last)["a.example"] == nil end)
    assert Hub.remote_channels(last, "a.example") == []
  end

  test "pending inbound handshakes have a fixed capacity" do
    workers =
      for _ <- 1..32,
          do:
            spawn(fn ->
              receive do
                :stop -> :ok
              end
            end)

    on_exit(fn -> Enum.each(workers, &send(&1, :stop)) end)

    for worker <- workers, do: assert(:ok = GenServer.call(Hub, {:reserve_inbound, worker}))

    extra =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(extra, :stop) end)
    assert {:error, :capacity} = GenServer.call(Hub, {:reserve_inbound, extra})

    send(hd(workers), :stop)
    assert eventually(fn -> map_size(:sys.get_state(Hub).pending) == 31 end)
    assert :ok = GenServer.call(Hub, {:reserve_inbound, extra})
  end

  test "a stalled peer is disconnected when its outbound mailbox reaches the limit", context do
    assert {:ok, client} = connect(context)
    assert {:ok, %{"type" => "hello"}} = Frame.recv(client, 5_000)
    assert :ok = Frame.send(client, Frame.hello("a.example", "Server Example"))
    assert_receive_empty_snapshot(client)
    assert eventually(fn -> Hub.status()["a.example"] == :connected end)

    peer_pid = :sys.get_state(Hub).links["a.example"]
    assert true = :erlang.suspend_process(peer_pid)
    on_exit(fn -> if Process.alive?(peer_pid), do: :erlang.resume_process(peer_pid) end)

    for sequence <- 1..1_100 do
      send(Hub, {:server_link_local_event, %{"type" => "user_remove", "sequence" => sequence}})
    end

    assert eventually(fn -> Hub.status()["a.example"] == :disconnected end)
    :ssl.close(client)
  end

  defp connect(%{port: port, peer: peer, ca: ca}) do
    :ssl.connect(~c"127.0.0.1", port,
      certfile: peer.certfile,
      keyfile: peer.keyfile,
      cacertfile: ca.certfile,
      verify: :verify_peer,
      server_name_indication: :disable,
      versions: [:"tlsv1.3"],
      active: false,
      mode: :binary
    )
  end

  defp assert_receive_empty_snapshot(client) do
    assert {:ok, %{"type" => "route_up", "origin" => "irc.test"}} = Frame.recv(client, 5_000)
    assert {:ok, %{"type" => "snapshot_begin", "count" => 0}} = Frame.recv(client, 5_000)
    assert {:ok, %{"type" => "snapshot_end"}} = Frame.recv(client, 5_000)
  end

  defp certificate_authority(directory) do
    certfile = Path.join(directory, "ca.pem")
    keyfile = Path.join(directory, "ca.key")

    openssl!(
      ~w(req -x509 -newkey rsa:2048 -nodes -days 2 -sha256 -subj /CN=ElixIRCd-Test-CA -addext basicConstraints=critical,CA:TRUE -keyout #{keyfile} -out #{certfile})
    )

    %{certfile: certfile, keyfile: keyfile}
  end

  defp certificate(directory, name, hostname, ca) do
    certfile = Path.join(directory, "#{name}.pem")
    keyfile = Path.join(directory, "#{name}.key")
    csrfile = Path.join(directory, "#{name}.csr")
    extfile = Path.join(directory, "#{name}.ext")

    File.write!(
      extfile,
      "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=DNS:#{hostname},IP:127.0.0.1\n"
    )

    openssl!(~w(req -new -newkey rsa:2048 -nodes -sha256 -subj /CN=#{hostname} -keyout #{keyfile} -out #{csrfile}))

    openssl!(
      ~w(x509 -req -in #{csrfile} -CA #{ca.certfile} -CAkey #{ca.keyfile} -CAcreateserial -out #{certfile} -days 2 -sha256 -extfile #{extfile})
    )

    %{certfile: certfile, keyfile: keyfile}
  end

  defp link_listener(cert, ca) do
    [port: 0, bind_ip: {127, 0, 0, 1}, certfile: cert.certfile, keyfile: cert.keyfile, cacertfile: ca.certfile]
  end

  defp pin(%{certfile: certfile}) do
    certfile
    |> File.read!()
    |> :public_key.pem_decode()
    |> hd()
    |> elem(1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp openssl!(args) do
    {_output, 0} = System.cmd("openssl", args, stderr_to_stdout: true)
    :ok
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
