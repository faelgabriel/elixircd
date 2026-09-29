defmodule ElixIRCd.Commands.Mode do
  @moduledoc """
  This module defines the MODE command.

  MODE allows users to view and change user modes and channel modes.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [channel_name?: 1, channel_operator?: 1, irc_operator?: 1]

  alias ElixIRCd.Commands.Mode.ChannelModes
  alias ElixIRCd.Commands.Mode.UserModes
  alias ElixIRCd.Message
  alias ElixIRCd.ModeRegistry
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.ChannelList
  alias ElixIRCd.ServerLink.ChannelPayload
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.ModeMutation.Outbound
  alias ElixIRCd.StandardReply
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.Chanserv.ModeLock

  @type channel_mode_errors ::
          :channel_not_found
          | :user_channel_not_found
          | :user_is_not_operator
          | :too_many_modes
          | :network_directory_unavailable
          | :remote_mode_unavailable

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "MODE"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "MODE", params: []}) do
    send_needmoreparams_error(user)
  end

  @impl true
  def handle(user, %{command: "MODE", params: [target | rest], trailing: trailing}) do
    rest = if trailing != nil, do: rest ++ [trailing], else: rest

    [mode_string, values] =
      case rest do
        [] -> [nil, nil]
        [mode_string | values] -> [mode_string, values]
      end

    case channel_name?(target) do
      true -> handle_channel_mode(user, target, mode_string, values)
      false -> handle_user_mode(user, target, mode_string)
    end
  end

  @spec handle_channel_mode(User.t(), String.t(), String.t() | nil, list(String.t()) | nil) :: :ok
  defp handle_channel_mode(user, channel_name, nil, nil) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, _user_channel} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name),
         {:ok, selected} <- selected_mode_channel(channel) do
      mode_params =
        case ChannelModes.display_modes(selected.modes) do
          "" -> ["+"]
          modes -> String.split(modes, " ")
        end

      [
        %Message{command: :rpl_channelmodeis, params: [user.nick, selected.name | mode_params]},
        %Message{
          command: :rpl_creationtime,
          params: [user.nick, selected.name, to_string(DateTime.to_unix(selected.created_at))]
        }
      ]
      |> Dispatcher.broadcast(:server, user)
    else
      {:error, error} -> send_channel_mode_error(error, user, channel_name)
    end
  end

  defp handle_channel_mode(user, channel_name, mode_string, values) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, user_channel} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name),
         {validated_modes, invalid_modes} <- ChannelModes.parse_mode_changes(mode_string, values),
         :ok <- check_mode_limit(validated_modes) do
      {validated_filtered_modes, listing_modes, _missing_value_modes} =
        ChannelModes.filter_mode_changes(validated_modes)

      process_channel_mode_changes(
        user,
        user_channel,
        channel,
        channel_name,
        validated_filtered_modes,
        listing_modes,
        invalid_modes
      )
    else
      {:error, channel_mode_error} -> send_channel_mode_error(channel_mode_error, user, channel_name)
    end
  end

  defp selected_mode_channel(channel) do
    local_id = Application.fetch_env!(:elixircd, :server)[:hostname]
    links_enabled? = Application.fetch_env!(:elixircd, :server_links)[:enabled]

    case ChannelDirectory.get(channel.name) do
      {:ok, %ChannelView{origin: ^local_id}} ->
        {:ok, channel}

      {:ok, %ChannelView{channel: payload}} ->
        case ChannelPayload.to_local(payload) do
          {:ok, attrs} -> {:ok, %{channel | modes: attrs.modes, created_at: attrs.created_at}}
          {:error, :invalid_channel} -> {:error, :network_directory_unavailable}
        end

      :unavailable when links_enabled? ->
        {:error, :network_directory_unavailable}

      :error when links_enabled? ->
        {:error, :network_directory_unavailable}

      _ ->
        {:ok, channel}
    end
  end

  @spec process_channel_mode_changes(
          User.t(),
          UserChannel.t(),
          Channel.t(),
          String.t(),
          [ChannelModes.mode_change()],
          [ModeRegistry.channel_mode()],
          [String.t()]
        ) :: :ok
  defp process_channel_mode_changes(
         user,
         _user_channel,
         channel,
         _channel_name,
         [],
         listing_modes,
         invalid_modes
       )
       when listing_modes != [] do
    send_channel_mode_listing(listing_modes, user, channel)
    send_invalid_modes(invalid_modes, user)
  end

  defp process_channel_mode_changes(
         user,
         user_channel,
         channel,
         channel_name,
         validated_modes,
         listing_modes,
         invalid_modes
       ) do
    case check_user_permission(user_channel) do
      :ok ->
        case network_mode_authority(channel.name) do
          :ok ->
            {updated_channel, applied_changes} = ChannelModes.apply_mode_changes(user, channel, validated_modes)

            broadcast_channel_mode_changes(user, updated_channel, applied_changes)
            enforce_registered_mode_lock(updated_channel)
            send_channel_mode_listing(listing_modes, user, updated_channel)
            send_invalid_modes(invalid_modes, user)

          {:remote, origin} ->
            request_remote_mode(user, origin, channel, validated_modes)
            send_channel_mode_listing(listing_modes, user, channel)
            send_invalid_modes(invalid_modes, user)

          {:error, error} ->
            send_channel_mode_error(error, user, channel_name)
        end

      {:error, error} ->
        send_channel_mode_error(error, user, channel_name)
    end
  end

  defp request_remote_mode(_user, _origin, _channel, []), do: :ok

  defp request_remote_mode(user, origin, channel, mode_changes) do
    {mode_string, values} = ChannelModes.encode_mode_changes(mode_changes)

    request = %Outbound{
      sender_pid: user.pid,
      authority: origin,
      channel: channel.name,
      mode_string: mode_string,
      values: values
    }

    Observability.defer_effect(fn ->
      if Hub.request_mode(request) == :unavailable,
        do: send_channel_mode_error(:remote_mode_unavailable, user, channel.name)
    end)
  end

  defp network_mode_authority(channel_name) do
    local_id = Application.fetch_env!(:elixircd, :server)[:hostname]
    links_enabled? = Application.fetch_env!(:elixircd, :server_links)[:enabled]

    case ChannelDirectory.get(channel_name) do
      {:ok, %ChannelView{origin: ^local_id}} -> :ok
      {:ok, %ChannelView{origin: origin}} -> {:remote, origin}
      :unavailable when links_enabled? -> {:error, :network_directory_unavailable}
      :error when links_enabled? -> {:error, :network_directory_unavailable}
      _ -> :ok
    end
  end

  @spec enforce_registered_mode_lock(Channel.t()) :: :ok
  defp enforce_registered_mode_lock(channel) do
    case RegisteredChannels.get_by_name(channel.name) do
      {:ok, registered_channel} ->
        ModeLock.reconcile_and_broadcast(channel, registered_channel)
        :ok

      {:error, :registered_channel_not_found} ->
        :ok
    end
  end

  @spec broadcast_channel_mode_changes(User.t(), Channel.t(), [ChannelModes.mode_change()]) :: :ok
  defp broadcast_channel_mode_changes(_user, _channel, []), do: :ok

  defp broadcast_channel_mode_changes(user, channel, applied_changes) do
    channel_users = UserChannels.get_by_channel_name(channel.name)
    user_pids = Enum.map(channel_users, & &1.user_pid)
    users = Users.get_by_pids(user_pids)

    %Message{command: "MODE", params: [channel.name, ChannelModes.display_mode_changes(applied_changes)]}
    |> Dispatcher.broadcast(user, users)
  end

  @spec check_user_permission(UserChannel.t()) :: :ok | {:error, :user_is_not_operator}
  defp check_user_permission(user_channel) do
    case channel_operator?(user_channel) do
      true -> :ok
      false -> {:error, :user_is_not_operator}
    end
  end

  @spec check_mode_limit([ChannelModes.mode_change()]) :: :ok | {:error, :too_many_modes}
  defp check_mode_limit(validated_modes) do
    max_modes_limit = Application.fetch_env!(:elixircd, :channel)[:max_modes_per_command]

    if length(validated_modes) > max_modes_limit do
      {:error, :too_many_modes}
    else
      :ok
    end
  end

  @spec send_channel_mode_listing([ElixIRCd.ModeRegistry.channel_mode()], User.t(), Channel.t()) :: :ok
  defp send_channel_mode_listing([], _user, _channel), do: :ok

  defp send_channel_mode_listing(listing_modes, user, channel) do
    Enum.each(listing_modes, fn mode ->
      case mode do
        :b -> send_ban_list(user, channel)
        :e -> send_except_list(user, channel)
        :I -> send_invex_list(user, channel)
      end
    end)
  end

  @spec send_ban_list(User.t(), Channel.t()) :: :ok
  defp send_ban_list(user, channel),
    do: send_channel_list(user, channel, :b, :rpl_banlist, :rpl_endofbanlist, "Ban", "End of channel ban list")

  @spec send_except_list(User.t(), Channel.t()) :: :ok
  defp send_except_list(user, channel),
    do:
      send_channel_list(
        user,
        channel,
        :e,
        :rpl_exceptlist,
        :rpl_endofexceptlist,
        "Except",
        "End of channel except list"
      )

  @spec send_invex_list(User.t(), Channel.t()) :: :ok
  defp send_invex_list(user, channel),
    do: send_channel_list(user, channel, :I, :rpl_invexlist, :rpl_endofinvexlist, "Invex", "End of channel invex list")

  defp send_channel_list(user, channel, kind, item_command, end_command, label, ending) do
    case ChannelList.read(channel, kind) do
      {:ok, entries} ->
        max_entries = Application.fetch_env!(:elixircd, :channel)[:max_list_entries] |> Map.fetch!(kind)

        entries
        |> Enum.take(max_entries)
        |> Enum.each(fn %ChannelList.Entry{} = entry ->
          timestamp = entry.set_at |> DateTime.to_unix() |> Integer.to_string()

          %Message{command: item_command, params: [user.nick, channel.name, entry.mask, entry.setter, timestamp]}
          |> Dispatcher.broadcast(:server, user)
        end)

        if length(entries) > max_entries do
          description =
            "#{label} list for #{channel.name} too long, showing first #{max_entries} of #{length(entries)} entries"

          send_list_truncated(user, channel, Atom.to_string(kind), description)
        end

        %Message{command: end_command, params: [user.nick, channel.name], trailing: ending}
        |> Dispatcher.broadcast(:server, user)

      {:error, :network_directory_unavailable} ->
        send_channel_mode_error(:network_directory_unavailable, user, channel.name)
    end
  end

  @spec send_list_truncated(User.t(), Channel.t(), String.t(), String.t()) :: :ok
  defp send_list_truncated(user, channel, mode, description) do
    reply = %StandardReply{
      type: :warn,
      command: "MODE",
      code: "LIST_TRUNCATED",
      context: [channel.name, mode],
      description: description
    }

    fallback = %Message{command: "NOTICE", params: [user.nick], trailing: description}

    Dispatcher.broadcast_standard_reply(reply, :server, user, fallback)
  end

  @spec send_channel_mode_error(channel_mode_errors(), User.t(), String.t()) :: :ok
  defp send_channel_mode_error(:channel_not_found, user, channel_name) do
    %Message{command: :err_nosuchchannel, params: [user.nick, channel_name], trailing: "No such channel"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_channel_mode_error(:user_channel_not_found, user, channel_name) do
    %Message{command: :err_notonchannel, params: [user.nick, channel_name], trailing: "You're not on that channel"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_channel_mode_error(:user_is_not_operator, user, channel_name) do
    %Message{
      command: :err_chanoprivsneeded,
      params: [user.nick, channel_name],
      trailing: "You're not a channel operator"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_channel_mode_error(:network_directory_unavailable, user, channel_name) do
    %Message{
      command: :err_unavailresource,
      params: [user.nick, channel_name],
      trailing: "Channel state is temporarily unavailable on this server"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_channel_mode_error(:remote_mode_unavailable, user, channel_name) do
    %Message{
      command: :err_unavailresource,
      params: [user.nick, channel_name],
      trailing: "Channel modes are temporarily unavailable on this server"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_channel_mode_error(:too_many_modes, user, channel_name) do
    max_modes_limit = Application.fetch_env!(:elixircd, :channel)[:max_modes_per_command]

    %Message{
      command: :err_unknownmode,
      params: [user.nick, channel_name],
      trailing: "Too many channel modes in one command (maximum is #{max_modes_limit})"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_user_mode(User.t(), String.t(), String.t() | nil) :: :ok
  defp handle_user_mode(%{nick: user_nick} = user, receiver_nick, nil) when user_nick == receiver_nick do
    send_umodeis_response(user, UserModes.display_modes(user, user.modes))
  end

  defp handle_user_mode(%{nick: user_nick} = user, receiver_nick, nil) when user_nick != receiver_nick do
    if irc_operator?(user) do
      case Users.get_by_nick(receiver_nick) do
        {:ok, target_user} -> send_umodeis_response(user, UserModes.display_modes(user, target_user.modes))
        {:error, :user_not_found} -> send_user_not_found_error(user, receiver_nick)
      end
    else
      send_usersdontmatch_error(user)
    end
  end

  defp handle_user_mode(%{nick: user_nick} = user, receiver_nick, _mode_string) when user_nick != receiver_nick do
    send_usersdontmatch_error(user)
  end

  defp handle_user_mode(user, _receiver_nick, mode_string) when is_binary(mode_string) do
    {validated_modes, invalid_modes} = UserModes.parse_mode_changes(mode_string)
    {updated_user, applied_changes, unauthorized_modes} = UserModes.apply_mode_changes(user, validated_modes)

    if applied_changes != [] do
      mode_changes_display = UserModes.display_mode_changes(applied_changes)
      send_user_mode_change(updated_user, updated_user.nick, mode_changes_display, updated_user)
    end

    send_noprivileges_error(user, unauthorized_modes)
    send_invalid_modes(invalid_modes, updated_user)
  end

  @spec send_invalid_modes(list(String.t()), User.t()) :: :ok
  defp send_invalid_modes([], _user), do: :ok

  defp send_invalid_modes(invalid_modes, user) do
    invalid_modes
    |> Enum.each(fn mode ->
      %Message{command: :err_unknownmode, params: [user.nick, mode], trailing: "is unknown mode char to me"}
      |> Dispatcher.broadcast(:server, user)
    end)
  end

  @spec send_user_not_found_error(User.t(), String.t()) :: :ok
  defp send_user_not_found_error(user, receiver_nick) do
    %Message{command: :err_nosuchnick, params: [user.nick, receiver_nick], trailing: "No such nick"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec send_umodeis_response(User.t(), String.t()) :: :ok
  defp send_umodeis_response(user, modes) do
    %Message{command: :rpl_umodeis, params: [user.nick, modes]}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec send_usersdontmatch_error(User.t()) :: :ok
  defp send_usersdontmatch_error(user) do
    %Message{command: :err_usersdontmatch, params: [user.nick], trailing: "Cannot change mode for other users"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec send_needmoreparams_error(User.t()) :: :ok
  defp send_needmoreparams_error(user) do
    %Message{command: :err_needmoreparams, params: [user.nick, "MODE"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec send_user_mode_change(User.t(), String.t(), String.t(), User.t() | list(User.t())) :: :ok
  defp send_user_mode_change(user, target_nick, mode_changes, targets) do
    %Message{command: "MODE", params: [target_nick, mode_changes]}
    |> Dispatcher.broadcast(user, targets)
  end

  @spec send_noprivileges_error(User.t(), list({atom(), String.t()})) :: :ok
  defp send_noprivileges_error(_user, []), do: :ok

  defp send_noprivileges_error(user, unauthorized_modes) do
    unauthorized_modes
    |> Enum.each(fn {_, mode} ->
      %Message{
        command: :err_noprivileges,
        params: [user.nick],
        trailing: "Permission Denied- You don't have privileges to change mode #{mode}"
      }
      |> Dispatcher.broadcast(:server, user)
    end)
  end
end
