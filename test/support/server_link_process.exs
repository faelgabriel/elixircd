alias ElixIRCd.ServerLink.Hub
alias ElixIRCd.ServerLink.Projector

[manifest_path] = System.argv()
manifest = manifest_path |> File.read!() |> Jason.decode!()
Logger.configure(level: :error)

for {key, value} <- Config.Reader.read!("config/elixircd.exs") |> Keyword.fetch!(:elixircd) do
  Application.put_env(:elixircd, key, value)
end

Application.put_env(:mnesia, :dir, String.to_charlist(manifest["database_dir"]))
Application.put_env(:elixircd, :server, hostname: manifest["id"], name: manifest["network"])
:ok = ElixIRCd.Utils.Mnesia.setup_mnesia(recreate: true)

{:ok, projector} = Projector.start_link(name: nil, id: manifest["id"])

listen = [
  port: 0,
  bind_ip: {127, 0, 0, 1},
  certfile: manifest["certificate"],
  keyfile: manifest["key"],
  cacertfile: manifest["ca"]
]

peer = %{
  id: manifest["peer_id"],
  host: "127.0.0.1",
  port: 1,
  certificate_sha256: manifest["peer_pin"]
}

{:ok, hub} =
  Hub.start_link(
    name: Hub,
    id: manifest["id"],
    network: manifest["network"],
    listen: listen,
    peers: [peer],
    projector: projector
  )

{:ok, port} = Hub.listener_port(hub)
{:ok, control} = :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])
{:ok, {_address, control_port}} = :inet.sockname(control)
IO.puts("S2S_READY #{port} #{control_port}")
{:ok, control_socket} = :gen_tcp.accept(control)

defmodule ServerLinkProcessControl do
  @moduledoc false

  alias ElixIRCd.Commands.Privmsg
  alias ElixIRCd.Factory
  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.ServerLink.Hub

  def run(socket, hub, origin, local_id) do
    with {:ok, line} <- :gen_tcp.recv(socket, 0),
         :ok <- handle_line(line, socket, hub, origin, local_id) do
      run(socket, hub, origin, local_id)
    else
      _ -> :ok
    end
  end

  defp handle_line("USERS\n", socket, hub, origin, _local_id) do
    users = Hub.remote_users(hub, origin)
    :gen_tcp.send(socket, "S2S_USERS #{Jason.encode!(users)}\n")
  end

  defp handle_line("CHANNELS\n", socket, hub, origin, _local_id) do
    channels = Hub.remote_channels(hub, origin)
    :gen_tcp.send(socket, "S2S_CHANNELS #{Jason.encode!(channels)}\n")
  end

  defp handle_line("CHANNEL_STATE\n", socket, hub, origin, _local_id) do
    channel_state = Hub.remote_channel_state(hub, origin)
    :gen_tcp.send(socket, "S2S_CHANNEL_STATE #{Jason.encode!(channel_state)}\n")
  end

  defp handle_line("ADD ChildUser\n", socket, _hub, _origin, local_id) do
    receiver = spawn(fn -> receiver_loop(socket) end)
    user = Factory.build(:user, nick: "ChildUser", hostname: local_id, pid: receiver)
    Memento.transaction!(fn -> Memento.Query.write(user) end)
    :gen_tcp.send(socket, "S2S_ADDED\n")
  end

  defp handle_line("ADD_CHANNEL #child\n", socket, _hub, _origin, _local_id) do
    channel = Factory.build(:channel, name: "#child")

    Memento.transaction!(fn ->
      {:ok, user} = Users.get_by_nick("ChildUser")
      membership = Factory.build(:user_channel, user_pid: user.pid, channel_name_key: channel.name_key, modes: [:o])
      ban = Factory.build(:channel_ban, channel_name_key: channel.name_key, mask: "*!*@blocked.test")
      Enum.each([channel, membership, ban], &Memento.Query.write/1)
    end)

    :gen_tcp.send(socket, "S2S_CHANNEL_ADDED\n")
  end

  defp handle_line("JOIN_PARENT\n", socket, hub, origin, _local_id) do
    parent = Enum.find(Hub.remote_channels(hub, origin), &(&1["name"] == "#parent"))
    {:ok, created_at, _offset} = DateTime.from_iso8601(parent["created_at"])

    Memento.transaction!(fn ->
      {:ok, user} = Users.get_by_nick("ChildUser")
      channel = Channels.create(%{name: parent["name"], created_at: created_at, creator: parent["creator"]})
      membership = Factory.build(:user_channel, user_pid: user.pid, channel_name_key: channel.name_key, modes: [:o])
      Memento.Query.write(membership)
    end)

    :gen_tcp.send(socket, "S2S_PARENT_JOINED\n")
  end

  defp handle_line("PART_PARENT\n", socket, _hub, _origin, _local_id) do
    Memento.transaction!(fn ->
      {:ok, user} = Users.get_by_nick("ChildUser")
      {:ok, membership} = UserChannels.get_by_user_pid_and_channel_name(user.pid, "#parent")
      UserChannels.delete(membership)
    end)

    :gen_tcp.send(socket, "S2S_PARENT_PARTED\n")
  end

  defp handle_line("SET_CHANNEL_N #child\n", socket, _hub, _origin, _local_id) do
    Memento.transaction!(fn ->
      {:ok, channel} = Channels.get_by_name("#child")
      Channels.update(channel, %{modes: [:n]})
    end)

    :gen_tcp.send(socket, "S2S_CHANNEL_MODE_SET\n")
  end

  defp handle_line("SET_R ChildUser\n", socket, _hub, _origin, _local_id) do
    Memento.transaction!(fn ->
      {:ok, user} = Users.get_by_nick("ChildUser")
      Users.update(user, %{modes: [:R]})
    end)

    :gen_tcp.send(socket, "S2S_MODE_SET\n")
  end

  defp handle_line("SEND ParentUser\n", socket, _hub, _origin, _local_id) do
    :ok =
      Observability.transaction(fn ->
        {:ok, user} = Users.get_by_nick("ChildUser")
        Privmsg.handle(user, %Message{command: "PRIVMSG", params: ["ParentUser"], trailing: "reply across link"})
      end)

    :gen_tcp.send(socket, "S2S_SENT\n")
  end

  defp handle_line("SEND_CHANNEL #parent\n", socket, _hub, _origin, _local_id) do
    :ok =
      Observability.transaction(fn ->
        {:ok, user} = Users.get_by_nick("ChildUser")

        Privmsg.handle(
          user,
          %Message{command: "PRIVMSG", params: ["#parent"], trailing: "channel reply across link"}
        )
      end)

    :gen_tcp.send(socket, "S2S_CHANNEL_SENT\n")
  end

  defp handle_line(_line, _socket, _hub, _origin, _local_id), do: :stop

  defp receiver_loop(socket) do
    receive do
      {:broadcast, wire} ->
        :gen_tcp.send(socket, "S2S_DELIVERED #{Base.encode64(wire)}\n")
        receiver_loop(socket)
    end
  end
end

ServerLinkProcessControl.run(control_socket, hub, manifest["peer_id"], manifest["id"])
