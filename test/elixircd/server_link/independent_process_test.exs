defmodule ElixIRCd.ServerLink.IndependentProcessTest do
  @moduledoc false
  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Commands.Ison
  alias ElixIRCd.Commands.Join
  alias ElixIRCd.Commands.Names
  alias ElixIRCd.Commands.Notice
  alias ElixIRCd.Commands.Privmsg
  alias ElixIRCd.Commands.Userhost
  alias ElixIRCd.Factory
  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.Projector

  @tag timeout: 60_000
  test "two isolated Mnesia processes exchange committed local users over TLS" do
    directory = Path.join(System.tmp_dir!(), "elixircd-process-link-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    ca = certificate_authority(directory)
    local = certificate(directory, "local", "irc.test", ca)
    remote = certificate(directory, "remote", "z.example", ca)

    manifest = %{
      id: "z.example",
      network: "Server Example",
      database_dir: Path.join(directory, "remote-mnesia"),
      certificate: remote.certfile,
      key: remote.keyfile,
      ca: ca.certfile,
      peer_id: "irc.test",
      peer_pin: pin(local)
    }

    manifest_path = Path.join(directory, "remote.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    executable = System.find_executable("mix")

    process =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 4096},
        args: ["run", "--no-start", "--no-compile", "test/support/server_link_process.exs", manifest_path],
        cd: File.cwd!(),
        env: [{~c"MIX_ENV", ~c"test"}]
      ])

    on_exit(fn -> if Port.info(process), do: Port.close(process) end)
    assert {:ok, ports_text} = await_line(process, "S2S_READY ", 30_000)
    [remote_port, control_port] = ports_text |> String.split(" ") |> Enum.map(&String.to_integer/1)
    assert {:ok, control} = :gen_tcp.connect({127, 0, 0, 1}, control_port, [:binary, packet: :line, active: false])
    on_exit(fn -> :gen_tcp.close(control) end)

    projector = start_supervised!({Projector, [name: nil, id: "irc.test"]})

    config = [
      name: Hub,
      id: "irc.test",
      network: "Server Example",
      projector: projector,
      listen: [
        port: 0,
        bind_ip: {127, 0, 0, 1},
        certfile: local.certfile,
        keyfile: local.keyfile,
        cacertfile: ca.certfile
      ],
      peers: [%{id: "z.example", host: "127.0.0.1", port: remote_port, certificate_sha256: pin(remote)}]
    ]

    hub = start_supervised!(Supervisor.child_spec({Hub, config}, id: :local_process_hub))
    assert eventually(fn -> Hub.status(hub)["z.example"] == :connected end)

    user = Factory.build(:user, nick: "ParentUser", hostname: "irc.test", pid: self())
    Memento.transaction!(fn -> Memento.Query.write(user) end)

    assert eventually(fn ->
             :ok = :gen_tcp.send(control, "USERS\n")

             case :gen_tcp.recv(control, 0, 1_000) do
               {:ok, "S2S_USERS " <> json} -> Enum.any?(Jason.decode!(json), &(&1["nick"] == "ParentUser"))
               _ -> false
             end
           end)

    :ok = :gen_tcp.send(control, "ADD ChildUser\n")
    assert {:ok, "S2S_ADDED\n"} = :gen_tcp.recv(control, 0, 5_000)
    assert eventually(fn -> Enum.any?(Hub.remote_users(hub, "z.example"), &(&1["nick"] == "ChildUser")) end)

    Memento.transaction!(fn ->
      assert :ok = Ison.handle(user, %Message{command: "ISON", params: ["ChildUser", "MissingUser"]})
      assert :ok = Userhost.handle(user, %Message{command: "USERHOST", params: ["ChildUser"]})
    end)

    assert_receive {:broadcast, ":irc.test 303 ParentUser :ChildUser\r\n"}
    assert_receive {:broadcast, ":irc.test 302 ParentUser :ChildUser=+~username@z.example\r\n"}

    assert_raise RuntimeError, "rollback", fn ->
      Observability.transaction(fn ->
        Privmsg.handle(user, %Message{command: "PRIVMSG", params: ["ChildUser"], trailing: "aborted message"})
        raise "rollback"
      end)
    end

    assert {:error, :timeout} = :gen_tcp.recv(control, 0, 200)

    assert :ok =
             Observability.transaction(fn ->
               Privmsg.handle(user, %Message{command: "PRIVMSG", params: ["ChildUser"], trailing: "hello across link"})
             end)

    assert {:ok, "S2S_DELIVERED " <> encoded_wire} = :gen_tcp.recv(control, 0, 5_000)

    assert Base.decode64!(String.trim(encoded_wire)) =~
             ":ParentUser!~username@irc.test PRIVMSG ChildUser :hello across link\r\n"

    assert :ok =
             Observability.transaction(fn ->
               Notice.handle(user, %Message{command: "NOTICE", params: ["ChildUser"], trailing: "remote notice"})
             end)

    assert {:ok, "S2S_DELIVERED " <> encoded_notice} = :gen_tcp.recv(control, 0, 5_000)

    assert Base.decode64!(String.trim(encoded_notice)) =~
             ":ParentUser!~username@irc.test NOTICE ChildUser :remote notice\r\n"

    :ok = :gen_tcp.send(control, "SEND ParentUser\n")
    assert {:ok, "S2S_SENT\n"} = :gen_tcp.recv(control, 0, 5_000)
    assert_receive {:broadcast, ":ChildUser!~username@z.example PRIVMSG ParentUser :reply across link\r\n"}, 5_000

    :ok = :gen_tcp.send(control, "SET_R ChildUser\n")
    assert {:ok, "S2S_MODE_SET\n"} = :gen_tcp.recv(control, 0, 5_000)

    assert eventually(fn ->
             Enum.any?(Hub.remote_users(hub, "z.example"), fn remote_user ->
               remote_user["nick"] == "ChildUser" and "R" in remote_user["modes"]
             end)
           end)

    assert :ok =
             Observability.transaction(fn ->
               Privmsg.handle(user, %Message{command: "PRIVMSG", params: ["ChildUser"], trailing: "blocked by R"})
             end)

    assert {:error, :timeout} = :gen_tcp.recv(control, 0, 200)

    parent_channel = Factory.build(:channel, name: "#parent")

    membership =
      Factory.build(:user_channel, user_pid: user.pid, channel_name_key: parent_channel.name_key, modes: [:o])

    ban = Factory.build(:channel_ban, channel_name_key: parent_channel.name_key, mask: "*!*@blocked.test")
    invite = Factory.build(:channel_invite, user_pid: user.pid, channel_name_key: parent_channel.name_key)

    Memento.transaction!(fn ->
      Enum.each([parent_channel, membership, ban, invite], &Memento.Query.write/1)
    end)

    assert eventually(fn ->
             :ok = :gen_tcp.send(control, "CHANNELS\n")

             case :gen_tcp.recv(control, 0, 1_000) do
               {:ok, "S2S_CHANNELS " <> json} -> Enum.any?(Jason.decode!(json), &(&1["name"] == "#parent"))
               _ -> false
             end
           end)

    :ok = :gen_tcp.send(control, "CHANNEL_STATE\n")
    assert {:ok, "S2S_CHANNEL_STATE " <> channel_state_json} = :gen_tcp.recv(control, 0, 5_000)
    channel_state = Jason.decode!(channel_state_json)
    assert [%{"channel" => "#parent", "modes" => ["o"]}] = channel_state["members"]
    assert [%{"channel" => "#parent", "kind" => "b"}] = channel_state["lists"]
    assert [%{"channel" => "#parent"}] = channel_state["invites"]

    :ok = :gen_tcp.send(control, "JOIN_PARENT\n")
    assert {:ok, "S2S_PARENT_JOINED\n"} = :gen_tcp.recv(control, 0, 5_000)
    assert_receive {:broadcast, ":ChildUser!~username@z.example JOIN #parent\r\n"}, 5_000
    assert_receive {:broadcast, ":irc.test MODE #parent +o ChildUser\r\n"}, 5_000

    assert :ok =
             Observability.transaction(fn ->
               Privmsg.handle(user, %Message{command: "PRIVMSG", params: ["#parent"], trailing: "channel across link"})
             end)

    assert {:ok, "S2S_DELIVERED " <> encoded_channel} = :gen_tcp.recv(control, 0, 5_000)

    assert Base.decode64!(String.trim(encoded_channel)) =~
             ":ParentUser!~username@irc.test PRIVMSG #parent :channel across link\r\n"

    :ok = :gen_tcp.send(control, "SEND_CHANNEL #parent\n")
    assert {:ok, "S2S_CHANNEL_SENT\n"} = :gen_tcp.recv(control, 0, 5_000)
    assert_receive {:broadcast, ":ChildUser!~username@z.example PRIVMSG #parent :channel reply across link\r\n"}, 5_000

    :ok = :gen_tcp.send(control, "PART_PARENT\n")
    assert {:ok, "S2S_PARENT_PARTED\n"} = :gen_tcp.recv(control, 0, 5_000)
    assert_receive {:broadcast, ":ChildUser!~username@z.example PART #parent\r\n"}, 5_000

    :ok = :gen_tcp.send(control, "ADD_CHANNEL #child\n")
    assert {:ok, "S2S_CHANNEL_ADDED\n"} = :gen_tcp.recv(control, 0, 5_000)
    assert eventually(fn -> Enum.any?(Hub.remote_channels(hub, "z.example"), &(&1["name"] == "#child")) end)
    assert {:ok, %{origin: "z.example"}} = Hub.channel_authority(hub, "#child")

    assert {:ok, %{remote_members: [%{origin: "z.example", user: %{"nick" => "ChildUser"}}]}} =
             ChannelDirectory.get("#child")

    assert {:ok, %{remote_lists: [%{origin: "z.example", entry: %{"kind" => "b"}}]}} =
             ChannelDirectory.get("#child")

    Memento.transaction!(fn ->
      assert :ok = Names.handle(user, %Message{command: "NAMES", params: ["#child"]})
    end)

    assert_receive {:broadcast, ":irc.test 353 ParentUser = #child :@ChildUser\r\n"}
    assert_receive {:broadcast, ":irc.test 366 ParentUser #child :End of /NAMES list\r\n"}

    Memento.transaction!(fn ->
      assert {:ok, %{origin: "z.example"}} = ChannelDirectory.get("#child")
    end)

    remote_child = Enum.find(Hub.remote_channels(hub, "z.example"), &(&1["name"] == "#child"))
    {:ok, created_at, _offset} = DateTime.from_iso8601(remote_child["created_at"])

    Memento.transaction!(fn ->
      assert :ok = Join.handle(user, %Message{command: "JOIN", params: ["#child"]})
      assert {:ok, adopted} = Channels.get_by_name("#child")
      assert adopted.created_at == created_at
      assert {:ok, membership} = UserChannels.get_by_user_pid_and_channel_name(user.pid, "#child")
      assert membership.modes == []
    end)

    assert_receive {:broadcast, ":ParentUser!~username@irc.test JOIN #child\r\n"}
    assert_receive {:broadcast, ":irc.test 353 ParentUser = #child :@ChildUser ParentUser\r\n"}
    assert_receive {:broadcast, ":irc.test 366 ParentUser #child :End of /NAMES list\r\n"}

    assert eventually(fn ->
             match?({:ok, %{origin: "z.example"}}, Hub.channel_authority(hub, "#child"))
           end)

    assert {:ok, %{origin: "z.example"}} = ChannelDirectory.get("#child")

    assert {:ok, "S2S_DELIVERED " <> encoded_remote_join} = :gen_tcp.recv(control, 0, 5_000)
    assert Base.decode64!(String.trim(encoded_remote_join)) =~ ":ParentUser!~username@irc.test JOIN #child\r\n"

    :ok = :gen_tcp.send(control, "SET_CHANNEL_N #child\n")
    assert {:ok, "S2S_CHANNEL_MODE_SET\n"} = :gen_tcp.recv(control, 0, 5_000)

    assert eventually(fn ->
             match?(
               {:ok, %{origin: "z.example", channel: %{"modes" => [%{"name" => "n"}]}}},
               ChannelDirectory.get("#child")
             )
           end)

    :gen_tcp.close(control)
    assert eventually(fn -> Hub.remote_users(hub, "z.example") == [] end)
    assert_receive {:broadcast, ":ChildUser!~username@z.example QUIT :Server link lost\r\n"}
    assert Hub.remote_channels(hub, "z.example") == []
    assert {:ok, %{origin: "irc.test"}} = Hub.channel_authority(hub, "#child")

    assert {:ok, %{origin: "irc.test", channel: %{"creator" => "z.example", "modes" => []}}} =
             ChannelDirectory.get("#child")

    assert {:ok, %{remote_members: [], remote_lists: [], remote_invites: []}} = ChannelDirectory.get("#child")

    Memento.transaction!(fn ->
      assert :ok = Ison.handle(user, %Message{command: "ISON", params: ["ChildUser"]})
    end)

    assert_receive {:broadcast, ":irc.test 303 ParentUser :\r\n"}
  end

  defp await_line(process, prefix, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_line_until(process, prefix, deadline)
  end

  defp await_line_until(process, prefix, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^process, {:data, {_ending, line}}} ->
        if String.starts_with?(line, prefix) do
          {:ok, String.replace_prefix(line, prefix, "")}
        else
          await_line_until(process, prefix, deadline)
        end

      {^process, {:exit_status, status}} ->
        {:error, {:child_exit, status}}
    after
      remaining -> {:error, :timeout}
    end
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
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
end
