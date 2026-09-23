defmodule ElixIRCd.Server.Connection do
  @moduledoc """
  Module for handling IRC connections .
  """

  require Logger

  import ElixIRCd.Utils.MessageFilter, only: [filter_auditorium_users: 3]
  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Command
  alias ElixIRCd.History
  alias ElixIRCd.Message
  alias ElixIRCd.Metadata
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.ClientBatches
  alias ElixIRCd.Repositories.HistoricalUsers
  alias ElixIRCd.Repositories.Metrics
  alias ElixIRCd.Repositories.ReadMarkers
  alias ElixIRCd.Repositories.SaslSessions
  alias ElixIRCd.Repositories.UserAccepts
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.UserMonitors
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Repositories.UserSilences
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.NickEnforcement
  alias ElixIRCd.Server.RateLimiter
  alias ElixIRCd.Server.ResponseContext
  alias ElixIRCd.Server.Snotice
  alias ElixIRCd.StandardReply
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Monitor

  @type transport :: :tcp | :tls | :ws | :wss
  @type connection_data :: %{
          required(:ip_address) => :inet.ip_address(),
          required(:port_connected) => :inet.port_number(),
          optional(:client_port) => :inet.port_number()
        }

  # IRCv3 message-tags limits; the 512-byte message budget includes CRLF.
  @max_client_tag_data_length 4094
  @max_message_length 512
  @max_wire_length @max_client_tag_data_length + 2 + @max_message_length
  @invalid_utf8_description "Message rejected, your IRC software MUST use UTF-8 encoding on this network"

  @doc """
  Maximum client wire size, including IRCv3 tags and CRLF.
  """
  @spec max_wire_length() :: pos_integer()
  def max_wire_length, do: @max_wire_length

  @doc """
  Handles the connection establishment.
  """
  @spec handle_connect(pid :: pid(), transport :: transport(), connection_data :: connection_data()) :: :ok | :close
  def handle_connect(pid, transport, connection_data) do
    Logger.debug("Connection established: #{inspect(pid)} (#{transport})")

    case RateLimiter.check_connection(connection_data.ip_address) do
      :ok -> handle_success_connection(pid, transport, connection_data)
      {:error, :throttled, retry_after_ms} -> handle_throttled_connection(pid, retry_after_ms)
      {:error, :throttled_exceeded} -> :close
      {:error, :max_connections_exceeded} -> handle_max_connections_exceeded(pid)
    end
  end

  @spec handle_max_connections_exceeded(pid :: pid()) :: :close
  defp handle_max_connections_exceeded(pid) do
    %Message{command: "ERROR", params: [], trailing: "Too many simultaneous connections from your IP address."}
    |> Dispatcher.broadcast(nil, pid)

    :close
  end

  @spec handle_success_connection(pid :: pid(), transport :: transport(), connection_data :: connection_data()) :: :ok
  defp handle_success_connection(pid, transport, connection_data) do
    Memento.transaction!(fn ->
      modes = if transport in [:tls, :wss], do: [:Z], else: []
      Users.create(Map.merge(connection_data, %{pid: pid, transport: transport, modes: modes}))
      update_connection_stats()
    end)
  end

  @spec handle_throttled_connection(pid :: pid(), retry_after_ms :: non_neg_integer()) :: :close
  defp handle_throttled_connection(pid, retry_after_ms) do
    %Message{
      command: "ERROR",
      params: [],
      trailing: "Too many connections from your IP address. Try again in #{div(retry_after_ms, 1000)} seconds."
    }
    |> Dispatcher.broadcast(nil, pid)

    :close
  end

  @doc """
  Handles the incoming data packets.
  """
  @spec handle_receive(pid :: pid(), data :: String.t()) :: :ok | {:quit, String.t()}
  def handle_receive(pid, data) do
    Logger.debug("<- #{byte_size(data)} bytes")

    Memento.transaction!(fn ->
      case Users.get_by_pid(pid) do
        {:ok, user} -> handle_check_message(user, data)
        {:error, :user_not_found} -> Logger.debug("User not found on receive message for PID: #{inspect(pid)}")
      end
    end)
  end

  @spec handle_check_message(user :: User.t(), data :: String.t()) :: :ok | {:quit, String.t()}
  defp handle_check_message(user, data) do
    with :ok <- RateLimiter.check_message(user, data),
         :ok <- validate_input_length(data),
         :ok <- check_utf8_validity(data) do
      handle_valid_message(user, data)
    else
      {:error, :throttled, retry_after_ms} -> handle_throttled_message(user, data, retry_after_ms)
      {:error, :throttled_exceeded} -> handle_excess_flood(user)
      {:error, :invalid_utf8} -> handle_invalid_utf8(user, data)
      {:error, :input_too_long} -> handle_input_too_long(user)
    end
  end

  @spec check_utf8_validity(data :: String.t()) :: :ok | {:error, :invalid_utf8}
  defp check_utf8_validity(data) do
    utf8_only_enabled? = Application.fetch_env!(:elixircd, :settings)[:utf8_only]

    if utf8_only_enabled? and not String.valid?(data) do
      {:error, :invalid_utf8}
    else
      :ok
    end
  end

  @spec handle_invalid_utf8(user :: User.t(), data :: String.t()) :: :ok
  defp handle_invalid_utf8(user, data) do
    Logger.debug("Invalid UTF-8 message from user #{user.nick}: #{inspect(data)}")

    description = @invalid_utf8_description
    request = rejected_request(data)

    ResponseContext.with_command(user, request, fn ->
      reply = %StandardReply{type: :fail, command: request.command, code: "INVALID_UTF8", description: description}
      Dispatcher.broadcast(reply, :server, user)
    end)
  end

  # Parse only to recover correlation metadata; invalid input is never dispatched.
  @spec rejected_request(binary()) :: Message.t()
  defp rejected_request(data) do
    with :ok <- validate_input_length(data),
         {:ok, message} <- Message.parse(discard_invalid_tags(data)) do
      tags = Map.filter(message.tags, fn {_key, value} -> is_binary(value) and String.valid?(value) end)

      command =
        if Regex.match?(~r/\A[a-zA-Z]+\z/, message.command) and rejected_command_fits?(message.command),
          do: message.command,
          else: "*"

      %{message | command: command, tags: tags}
    else
      _ -> %Message{command: "*", params: []}
    end
  end

  # A hostile command token may itself exceed the reply's wire budget. In that case it cannot be relayed, so Standard
  # Replies specifies the `*` placeholder.
  @spec rejected_command_fits?(String.t()) :: boolean()
  defp rejected_command_fits?(command) do
    hostname = Application.fetch_env!(:elixircd, :server)[:hostname]
    byte_size(":#{hostname} FAIL #{command} INVALID_UTF8 :#{@invalid_utf8_description}\r\n") <= 512
  end

  @spec discard_invalid_tags(binary()) :: binary()
  defp discard_invalid_tags("@" <> data) do
    case :binary.split(data, " ") do
      [tags, rest] ->
        valid_tags = tags |> :binary.split(";", [:global]) |> Enum.filter(&String.valid?/1) |> Enum.join(";")
        "@" <> valid_tags <> " " <> rest

      [_tags] ->
        ""
    end
  end

  defp discard_invalid_tags(data), do: data

  @spec handle_valid_message(user :: User.t(), data :: String.t()) :: :ok | {:quit, String.t()}
  defp handle_valid_message(user, data) do
    case Message.parse(data) do
      {:ok, message} ->
        updated_user = Users.update(user, %{last_activity: :erlang.system_time(:second)})
        Command.dispatch(updated_user, message)

      {:error, error} ->
        Logger.debug("Failed to handle message #{inspect(data)}: #{error}")
    end
  end

  @spec handle_input_too_long(User.t()) :: :ok
  defp handle_input_too_long(user) do
    %Message{command: :err_inputtoolong, params: [user_reply(user)], trailing: "Input line was too long"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec validate_input_length(binary()) :: :ok | {:error, :input_too_long}
  defp validate_input_length(data) when byte_size(data) > @max_wire_length, do: {:error, :input_too_long}

  defp validate_input_length("@" <> data = input) do
    with :ok <- validate_tag_data_length(input) do
      case :binary.split(data, " ") do
        [_tags, message] -> validate_message_length(message)
        [_tags] -> :ok
      end
    end
  end

  defp validate_input_length(data), do: validate_message_length(data)

  @spec validate_message_length(binary()) :: :ok | {:error, :input_too_long}
  defp validate_message_length(data) do
    # Reserve CRLF space even for WebSocket messages and TCP lines ending in LF.
    length = byte_size(data)

    ending_length =
      cond do
        length >= 2 and binary_part(data, length - 2, 2) == "\r\n" -> 2
        length >= 1 and binary_part(data, length - 1, 1) == "\n" -> 1
        true -> 0
      end

    if length - ending_length <= @max_message_length - 2, do: :ok, else: {:error, :input_too_long}
  end

  @spec validate_tag_data_length(String.t()) :: :ok | {:error, :input_too_long}
  defp validate_tag_data_length("@" <> data) do
    tag_data_length =
      case :binary.match(data, " ") do
        {length, 1} -> length
        :nomatch -> byte_size(data)
      end

    if tag_data_length > @max_client_tag_data_length do
      {:error, :input_too_long}
    else
      :ok
    end
  end

  @spec handle_throttled_message(User.t(), binary(), non_neg_integer()) :: :ok
  defp handle_throttled_message(user, data, retry_after_ms) do
    request = rejected_request(data)

    description =
      "Please slow down. You are sending messages too fast. Try again in #{div(retry_after_ms, 1000)} seconds."

    ResponseContext.with_command(user, request, fn ->
      if request.command == "SETNAME" and user.registered and
           Application.fetch_env!(:elixircd, :capabilities)[:setname] do
        reply = %StandardReply{
          type: :fail,
          command: "SETNAME",
          code: "CANNOT_CHANGE_REALNAME",
          description: description
        }

        Dispatcher.broadcast(reply, :server, user)
      else
        message = %Message{command: "NOTICE", params: [user_reply(user)], trailing: description}
        Dispatcher.broadcast(message, :server, user)
      end
    end)
  end

  @spec handle_excess_flood(user :: User.t()) :: {:quit, String.t()}
  defp handle_excess_flood(user) do
    if SaslSessions.exists?(user.pid) do
      SaslSessions.delete(user.pid)

      %Message{command: :err_saslfail, params: [user_reply(user)], trailing: "SASL authentication failed: Excess flood"}
      |> Dispatcher.broadcast(:server, user)
    end

    %Message{command: "ERROR", params: [], trailing: "Excess flood"}
    |> Dispatcher.broadcast(nil, user)

    if user.registered, do: send_flood_snotice(user)

    {:quit, "Excess flood"}
  end

  @spec send_flood_snotice(User.t()) :: :ok
  defp send_flood_snotice(user) do
    user_info = Snotice.format_user_info(user)
    Snotice.broadcast(:flood, "Excess flood from #{user_info}")
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
    NickEnforcement.cancel(pid)

    Memento.transaction!(fn ->
      Users.get_by_pid(pid)
      |> case do
        {:ok, user} ->
          disconnect_user(user, reason)

        {:error, :user_not_found} ->
          :ok
      end
    end)
  end

  defp disconnect_user(user, reason) do
    result = handle_quit(user, reason)
    if is_nil(user.identified_as), do: user |> History.identity_key() |> ReadMarkers.delete_owner()
    result
  end

  @spec handle_quit(user :: User.t(), quit_message :: String.t()) :: :ok
  defp handle_quit(%{registered: true} = user, quit_message) do
    # Get all user_channels for the quitting user
    quitting_user_channels = UserChannels.get_by_user_pid(user.pid)

    # List of all channel names the quitting user is a member of
    all_channel_name_keys = Enum.map(quitting_user_channels, & &1.channel_name_key)

    # List of all user_channel records for channels the quitting user is a member of, excluding himself
    all_user_channels_without_user =
      UserChannels.get_by_channel_names(all_channel_name_keys)
      |> Enum.reject(fn user_channel -> user_channel.user_pid == user.pid end)

    # Apply auditorium mode filtering per channel
    filtered_user_channels =
      Enum.flat_map(quitting_user_channels, fn quitting_uc ->
        # Get channel to check its modes
        {:ok, channel} = Channels.get_by_name(quitting_uc.channel_name_key)

        # Get all user_channels for this specific channel
        all_user_channels_without_user
        |> Enum.filter(fn uc -> uc.channel_name_key == quitting_uc.channel_name_key end)
        |> filter_auditorium_users(quitting_uc, channel.modes)
      end)
      |> Enum.uniq_by(& &1.user_pid)

    # Extract PIDs and get Users
    all_shared_unique_user_pids = Enum.map(filtered_user_channels, & &1.user_pid)
    all_shared_unique_users = Users.get_by_pids(all_shared_unique_user_pids)

    # Find channels with no other users remaining after removing the quitting user
    channels_with_no_other_users =
      all_channel_name_keys
      |> Enum.filter(fn channel_name_key ->
        # Check if no user_channel records remain for this channel after removing the quitting user
        not Enum.any?(all_user_channels_without_user, fn user_channel ->
          user_channel.channel_name_key == channel_name_key
        end)
      end)

    Enum.each(all_channel_name_keys, fn channel_name ->
      History.record_channel_event(%Message{command: "QUIT", params: [], trailing: quit_message}, user, channel_name)
    end)

    Monitor.notify_offline(user)
    Metadata.disconnect(user)
    ClientBatches.delete_by_user_pid(user.pid)

    ChannelInvites.delete_by_user_pid(user.pid)
    UserChannels.delete_by_user_pid(user.pid)
    UserAccepts.delete_by_user_pid(user.pid)
    UserAccepts.delete_by_accepted_user_pid(user.pid)
    UserSilences.delete_by_user_pid(user.pid)
    UserMonitors.delete_by_user_pid(user.pid)
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

    %Message{command: "QUIT", params: [], trailing: quit_message}
    |> Dispatcher.broadcast(user, all_shared_unique_users)

    send_quit_snotice(user, quit_message)
  end

  defp handle_quit(user, _quit_message) do
    Metadata.disconnect(user)
    ClientBatches.delete_by_user_pid(user.pid)
    Users.delete(user)
  end

  @spec send_quit_snotice(User.t(), String.t()) :: :ok
  defp send_quit_snotice(user, quit_message) do
    user_info = Snotice.format_user_info(user)
    Snotice.broadcast(:quit, "Client exiting: #{user_info} (#{quit_message})")
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
