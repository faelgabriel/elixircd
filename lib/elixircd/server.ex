defmodule ElixIRCd.Server do
  @moduledoc """
  Module for the server protocol.
  """

  @behaviour :ranch_protocol

  require Logger

  import ElixIRCd.Helper, only: [build_user_mask: 1, get_socket_port: 1]

  alias ElixIRCd.Command
  alias ElixIRCd.Message
  alias ElixIRCd.Repository.ChannelInvites
  alias ElixIRCd.Repository.HistoricalUsers
  alias ElixIRCd.Repository.UserChannels
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @doc """
  Starts a linked user connection process for the server protocol.

  This function initializes the server process and links it to the calling process.

  ## Parameters
  - `ref`: The reference to the Ranch listener.
  - `transport`: The transport module (:ranch_tcp or :ranch_ssl).
  - `opts`: Options for the server.

  ## Returns
  - `{:ok, pid}` on successful start of the process.
  """
  @spec start_link(ref :: pid(), transport :: module(), opts :: keyword()) :: {:ok, pid()}
  def start_link(ref, transport, opts) do
    {:ok, spawn_link(__MODULE__, :init, [ref, transport, opts])}
  end

  @doc """
  Initializes the connection to the server.

  This function is called after a successful connection is established.

  ## Parameters
  - `ref`: The reference to the Ranch listener.
  - `transport`: The transport module.
  - `_opts`: Options for the server (currently not in use).

  ## Returns
  - `:ok` if the connection is successfully handled.
  - `:error` in case of an error.
  """
  @spec init(ref :: pid(), transport :: atom(), _opts :: keyword()) :: :ok | :error
  def init(ref, transport, _opts) do
    Logger.debug("New connection: #{inspect(ref)} (#{inspect(transport)})")

    :ranch.handshake(ref)
    |> case do
      {:ok, socket} ->
        handle_connect(socket, transport, self())
        handle_listening(socket, transport)

      reason ->
        Logger.critical("Error initializing connection: #{inspect(reason)}")
        :error
    end
  end

  @spec handle_connect(socket :: :inet.socket(), transport :: atom(), pid :: pid()) :: :ok
  defp handle_connect(socket, transport, pid) do
    Logger.debug("Connection established: #{inspect(socket)}")

    Memento.transaction!(fn ->
      modes = if transport == :ranch_ssl, do: ["Z"], else: []
      Users.create(%{port: get_socket_port(socket), socket: socket, transport: transport, pid: pid, modes: modes})
    end)

    transport.setopts(socket, [{:packet, :line}])
  end

  @spec handle_listening(:inet.socket(), atom()) :: :ok
  defp handle_listening(socket, transport) do
    transport.setopts(socket, active: :once)

    receive do
      {:tcp, ^socket, data} ->
        handle_packet(socket, data)
        |> handle_packet_result(socket, transport)

      {:ssl, ^socket, data} ->
        handle_packet(socket, data)
        |> handle_packet_result(socket, transport)

      {:tcp_closed, ^socket} ->
        handle_disconnect(socket, transport, "Connection Closed")

      {:ssl_closed, ^socket} ->
        handle_disconnect(socket, transport, "Connection Closed")

      {:tcp_error, ^socket, reason} ->
        Logger.warning("TCP connection error: #{inspect(reason)}")
        handle_disconnect(socket, transport, "Connection Error")

      {:ssl_error, ^socket, reason} ->
        Logger.warning("SSL connection error: #{inspect(reason)}")
        handle_disconnect(socket, transport, "Connection Error")

      {:disconnect, ^socket, reason} ->
        handle_disconnect(socket, transport, reason)
    after
      Application.get_env(:elixircd, :user)[:timeout] ->
        handle_disconnect(socket, transport, "Connection Timeout")
    end
  rescue
    exception ->
      stacktrace = __STACKTRACE__ |> Exception.format_stacktrace()
      Logger.critical("Error handling connection: #{inspect(exception)}\nStacktrace:\n#{stacktrace}")
      handle_disconnect(socket, transport, "Server Error")
  end

  @spec handle_packet(socket :: :inet.socket(), data :: String.t()) :: :ok | {:quit, String.t()}
  defp handle_packet(socket, data) do
    Logger.debug("<- #{inspect(data)}")

    Memento.transaction!(fn ->
      with {:ok, user} <- Users.get_by_port(get_socket_port(socket)),
           {:ok, message} <- Message.parse(data) do
        updated_user = Users.update(user, %{last_activity: :erlang.system_time(:second)})
        Command.handle(updated_user, message)
      else
        {:error, error} -> Logger.debug("Failed to handle packet #{inspect(data)}: #{error}")
      end
    end)
  end

  @spec handle_packet_result(:ok | {:quit, String.t()}, :inet.socket(), atom()) :: :ok
  defp handle_packet_result(:ok, socket, transport), do: handle_listening(socket, transport)
  defp handle_packet_result({:quit, reason}, socket, transport), do: handle_disconnect(socket, transport, reason)

  @spec handle_disconnect(socket :: :inet.socket(), transport :: atom(), reason :: String.t()) :: :ok
  defp handle_disconnect(socket, transport, reason) do
    Logger.debug("Connection #{inspect(socket)} terminated: #{inspect(reason)}")

    transport.close(socket)

    Memento.transaction!(fn ->
      Users.get_by_port(get_socket_port(socket))
      |> case do
        {:ok, user} -> handle_quit(user, reason)
        {:error, error} -> Logger.critical("Error handling disconnect: #{inspect(error)}")
      end
    end)
  end

  @spec handle_quit(user :: User.t(), quit_message :: String.t()) :: :ok
  defp handle_quit(%{registered: true} = user, quit_message) do
    all_channel_users =
      UserChannels.get_by_user_port(user.port)
      |> Enum.map(& &1.channel_name)
      |> UserChannels.get_by_channel_names()
      |> Enum.reject(fn user_channel -> user_channel.user_port == user.port end)
      |> Enum.group_by(& &1.user_port)
      |> Enum.map(fn {_key, user_channels} -> hd(user_channels) end)

    # Future: Delete channel if the channel is not registered and has no users
    ChannelInvites.delete_by_user_port(user.port)
    UserChannels.delete_by_user_port(user.port)
    Users.delete(user)

    HistoricalUsers.create(%{
      nick: user.nick,
      hostname: user.hostname,
      username: user.username,
      realname: user.realname,
      userid: user.userid
    })

    Message.build(%{prefix: build_user_mask(user), command: "QUIT", params: [], trailing: quit_message})
    |> Messaging.broadcast(all_channel_users)
  end

  defp handle_quit(user, _quit_message) do
    ChannelInvites.delete_by_user_port(user.port)
    UserChannels.delete_by_user_port(user.port)
    Users.delete(user)
  end
end
