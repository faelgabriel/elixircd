defmodule ElixIRCd.Server.Connection do
  @moduledoc """
  Module for handling IRC connections .
  """

  require Logger

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Command
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.HistoricalUsers
  alias ElixIRCd.Repositories.Metrics
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @type transport :: :tcp | :tls | :ws | :wss
  @type connection_data :: %{ip_address: :inet.ip_address(), port_connected: :inet.port_number()}

  @doc """
  Handles the connection establishment.
  """
  @spec handle_connect(pid :: pid(), transport :: transport(), connection_data :: connection_data()) :: :ok
  def handle_connect(pid, transport, connection_data) do
    Logger.debug("Connection established: #{inspect(pid)} (#{transport})")

    Memento.transaction!(fn ->
      modes = if transport in [:tls, :wss], do: ["Z"], else: []
      Users.create(Map.merge(connection_data, %{pid: pid, transport: transport, modes: modes}))
      update_connection_stats()
    end)
  end

  @doc """
  Handles the incoming data packets.
  """
  @spec handle_recv(pid :: pid(), data :: String.t()) :: :ok | {:quit, String.t()}
  def handle_recv(pid, data) do
    Logger.debug("<- #{inspect(data)}")

    Memento.transaction!(fn ->
      with {:ok, user} <- Users.get_by_pid(pid),
           {:ok, message} <- Message.parse(data) do
        updated_user = Users.update(user, %{last_activity: :erlang.system_time(:second)})
        Command.dispatch(updated_user, message)
      else
        {:error, error} -> Logger.debug("Failed to handle packet #{inspect(data)}: #{error}")
      end
    end)
  end

  @doc """
  Handles the outgoing data packets.
  """
  @spec handle_send(pid(), String.t()) :: :ok
  def handle_send(pid, data) do
    Logger.debug("-> #{inspect(data)}")
    send(pid, {:broadcast, data})
    :ok
  end

  @doc """
  Handles the connection termination.
  """
  @spec handle_disconnect(pid :: pid(), transport :: transport(), reason :: String.t()) :: :ok
  def handle_disconnect(pid, transport, reason) do
    Logger.debug("Connection #{inspect(pid)} (#{transport}) terminated: #{inspect(reason)}")

    Memento.transaction!(fn ->
      Users.get_by_pid(pid)
      |> case do
        {:ok, user} -> handle_quit(user, reason)
        {:error, :user_not_found} -> :ok
      end
    end)
  end

  @spec handle_quit(user :: User.t(), quit_message :: String.t()) :: :ok
  defp handle_quit(%{registered: true} = user, quit_message) do
    # List of all channel names the quitting user is a member of
    all_channel_name_keys =
      UserChannels.get_by_user_pid(user.pid)
      |> Enum.map(& &1.channel_name_key)

    # List of all user_channel records for channels the quitting user is a member of, excluding himself
    all_user_channels_without_user =
      UserChannels.get_by_channel_names(all_channel_name_keys)
      |> Enum.reject(fn user_channel -> user_channel.user_pid == user.pid end)

    # List of unique user_channel.user_pid records that share channels with the quitting user
    all_shared_unique_user_channels =
      all_user_channels_without_user
      |> Enum.uniq_by(& &1.user_pid)

    # Find channels with no other users remaining after removing the quitting user
    channels_with_no_other_users =
      all_channel_name_keys
      |> Enum.filter(fn channel_name_key ->
        # Check if no user_channel records remain for this channel after removing the quitting user
        not Enum.any?(all_user_channels_without_user, fn user_channel ->
          user_channel.channel_name_key == channel_name_key
        end)
      end)

    ChannelInvites.delete_by_user_pid(user.pid)
    UserChannels.delete_by_user_pid(user.pid)
    Users.delete(user)

    # Delete the channels that have no other users
    Enum.each(channels_with_no_other_users, fn channel_name_key ->
      ChannelInvites.delete_by_channel_name(channel_name_key)
      Channels.delete_by_name(channel_name_key)
    end)

    HistoricalUsers.create(%{
      nick_key: user.nick_key,
      nick: user.nick,
      hostname: user.hostname,
      ident: user.ident,
      realname: user.realname
    })

    Message.build(%{prefix: user_mask(user), command: "QUIT", params: [], trailing: quit_message})
    |> Dispatcher.broadcast(all_shared_unique_user_channels)
  end

  defp handle_quit(user, _quit_message) do
    Users.delete(user)
  end

  @spec update_connection_stats() :: :ok
  defp update_connection_stats do
    active_connections = Users.count_all()
    highest_connections = Metrics.get(:highest_connections)

    if active_connections > highest_connections do
      Metrics.update_counter(:highest_connections, active_connections - highest_connections)
    end

    Metrics.update_counter(:total_connections, 1)
    :ok
  end
end
