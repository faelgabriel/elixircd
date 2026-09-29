defmodule ElixIRCd.Commands.Privmsg do
  @moduledoc """
  This module defines the PRIVMSG command.

  PRIVMSG sends a private message to a user, channel, or service.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.MessageFilter,
    only: [
      filter_op_moderated_users: 3,
      private_ctcp_blocked?: 2,
      should_silence_message?: 2
    ]

  import ElixIRCd.Utils.Protocol,
    only: [channel_name?: 1, service_name?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserAccepts
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.ChannelMessage
  alias ElixIRCd.ServerLink.ChannelMessage.LocalSelection
  alias ElixIRCd.ServerLink.DirectMessage
  alias ElixIRCd.ServerLink.Directory
  alias ElixIRCd.Service
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.Statusmsg
  alias ElixIRCd.Utils.Targets

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "PRIVMSG"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "PRIVMSG", params: [targets | _], trailing: trailing} = message)
      # Handle PRIVMSG when either:
      # 1. A trailing message is provided (standard IRC format)
      # 2. The message is included in params (alternative client format)
      # The extract_message_text/1 function normalizes these different formats
      when trailing != nil or length(message.params) > 1 do
    message_text = extract_message_text(message)

    if message_text == "" and not ElixIRCd.Multiline.collecting?() do
      send_no_text_error(user)
    else
      Targets.split("PRIVMSG", targets)
      |> Enum.each(&handle_target(user, &1, message_text, message))
    end
  end

  def handle(user, %{command: "PRIVMSG", params: [_target]}) do
    send_no_text_error(user)
  end

  def handle(user, %{command: "PRIVMSG"}) do
    %Message{command: :err_needmoreparams, params: [user.nick, "PRIVMSG"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_target(User.t(), String.t(), String.t(), Message.t()) :: :ok
  defp handle_target(user, target, message_text, message) do
    case Statusmsg.parse(target) do
      {:ok, channel_name, status_prefix} ->
        handle_channel_message(user, channel_name, message_text, message.tags, target, status_prefix)

      :error ->
        handle_plain_target(user, target, message_text, message)
    end
  end

  defp handle_plain_target(user, target, message_text, message) do
    fantasy? = fantasy_command_message?(target, message_text)
    service? = service_name?(target)

    cond do
      ElixIRCd.Multiline.collecting?() and (fantasy? or service?) -> :ok
      fantasy? -> handle_fantasy_channel_message(user, target, message_text)
      channel_name?(target) -> handle_channel_message(user, target, message_text, message.tags)
      service? -> handle_service_message(user, target, %{message | params: [target | tl(message.params)]})
      true -> handle_user_message(user, target, message_text, message.tags)
    end
  end

  @spec send_no_text_error(User.t()) :: :ok
  defp send_no_text_error(user) do
    %Message{command: :err_notexttosend, params: [user.nick], trailing: "No text to send"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_channel_message(User.t(), String.t(), String.t(), Message.tags()) :: :ok
  defp handle_channel_message(user, channel_name, message_text, message_tags) do
    handle_channel_message(user, channel_name, message_text, message_tags, channel_name, nil)
  end

  @spec handle_channel_message(User.t(), String.t(), String.t(), Message.tags(), String.t(), String.t() | nil) :: :ok
  defp handle_channel_message(user, channel_name, message_text, message_tags, wire_target, status_prefix) do
    with_channel_message_permissions(user, channel_name, message_text, fn channel, user_channel ->
      if Application.fetch_env!(:elixircd, :server_links)[:enabled] and not ElixIRCd.Multiline.collecting?() do
        ChannelMessage.queue_local(user, channel, wire_target, "PRIVMSG", message_text, message_tags)
      else
        channel_users_without_user =
          UserChannels.get_by_channel_name(channel.name)
          |> Enum.reject(&(&1.user_pid == user.pid))
          |> maybe_filter_status(status_prefix)
          |> filter_op_moderated_users(user_channel, channel.modes)

        user_pids = Enum.map(channel_users_without_user, & &1.user_pid)
        users = Users.get_by_pids(user_pids)

        %Message{command: "PRIVMSG", params: [wire_target], trailing: message_text, tags: message_tags}
        |> Dispatcher.broadcast_with_echo(user, users)

        ChannelMessage.send_from_local(user, channel.name, wire_target, "PRIVMSG", message_text, message_tags)
      end
    end)
  end

  @spec maybe_filter_status([UserChannel.t()], String.t() | nil) :: [UserChannel.t()]
  defp maybe_filter_status(user_channels, nil), do: user_channels
  defp maybe_filter_status(user_channels, prefix), do: Enum.filter(user_channels, &Statusmsg.eligible?(&1, prefix))

  @spec handle_fantasy_channel_message(User.t(), String.t(), String.t()) :: :ok
  defp handle_fantasy_channel_message(user, channel_name, message_text) do
    with_channel_message_permissions(user, channel_name, message_text, fn channel, _user_channel ->
      Service.dispatch(user, "ChanServ", fantasy_command_list(channel.name, message_text))
    end)
  end

  @spec with_channel_message_permissions(
          User.t(),
          String.t(),
          String.t(),
          (Channel.t(), UserChannel.t() | nil -> :ok)
        ) :: :ok
  defp with_channel_message_permissions(user, channel_name, message_text, on_success) do
    user_channel = get_user_channel(user.pid, channel_name)

    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, %LocalSelection{channel: selected, view: view}} <- ChannelMessage.select_local(channel),
         :ok <- ChannelMessage.check_local_permissions(selected, view, user, user_channel, "PRIVMSG", message_text) do
      on_success.(selected, user_channel)
    else
      {:error, :channel_not_found} ->
        %Message{command: :err_nosuchchannel, params: [user.nick, channel_name], trailing: "No such channel"}
        |> Dispatcher.broadcast(:server, user)

      {:error, :delay_message_blocked, delay} ->
        %Message{
          command: :err_delaymessageblocked,
          params: [user.nick, channel_name],
          trailing: "You must wait #{delay} seconds after joining before speaking in this channel."
        }
        |> Dispatcher.broadcast(:server, user)

      {:error, :user_can_not_send} ->
        %Message{command: :err_cannotsendtochan, params: [user.nick, channel_name], trailing: "Cannot send to channel"}
        |> Dispatcher.broadcast(:server, user)

      {:error, :network_directory_unavailable} ->
        %Message{
          command: :err_unavailresource,
          params: [user.nick, channel_name],
          trailing: "Channel state is temporarily unavailable on this network"
        }
        |> Dispatcher.broadcast(:server, user)

      {:error, :user_muted} ->
        %Message{command: :err_cannotsendtochan, params: [user.nick, channel_name], trailing: "Cannot send to channel"}
        |> Dispatcher.broadcast(:server, user)

      {:error, :ctcp_blocked} ->
        %Message{
          command: :err_cannotsendtochan,
          params: [user.nick, channel_name],
          trailing: "Cannot send CTCP to channel (+C)"
        }
        |> Dispatcher.broadcast(:server, user)

      {:error, :formatting_blocked} ->
        %Message{
          command: :err_cannotsendtochan,
          params: [user.nick, channel_name],
          trailing: "Cannot send to channel (+c - no colors allowed)"
        }
        |> Dispatcher.broadcast(:server, user)

      {:error, :registered_only_speak} ->
        %Message{
          command: :err_needreggednick,
          params: [user.nick, channel_name],
          trailing: "You must be identified to speak in this channel (+M)"
        }
        |> Dispatcher.broadcast(:server, user)
    end
  end

  @spec get_user_channel(pid(), String.t()) :: UserChannel.t() | nil
  defp get_user_channel(user_pid, channel_name) do
    case UserChannels.get_by_user_pid_and_channel_name(user_pid, channel_name) do
      {:ok, user_channel} -> user_channel
      {:error, :user_channel_not_found} -> nil
    end
  end

  @spec fantasy_command_message?(String.t(), String.t()) :: boolean()
  defp fantasy_command_message?(target, message_text) do
    channel_name?(target) and fantasy_enabled?(target) and not is_nil(fantasy_command_list(target, message_text))
  end

  @spec fantasy_enabled?(String.t()) :: boolean()
  defp fantasy_enabled?(channel_name) do
    case RegisteredChannels.get_by_name(channel_name) do
      {:ok, registered_channel} ->
        registered_channel.settings.guard and registered_channel.settings.fantasy

      {:error, :registered_channel_not_found} ->
        false
    end
  end

  @spec fantasy_command_list(String.t(), String.t()) :: [String.t()] | nil
  defp fantasy_command_list(channel_name, message_text) do
    case String.split(message_text, ~r/\s+/, trim: true) do
      [command | args] ->
        case normalize_fantasy_command(command) do
          nil -> nil
          mapped_command -> [mapped_command, channel_name | args]
        end

      [] ->
        nil
    end
  end

  @spec normalize_fantasy_command(String.t()) :: String.t() | nil
  defp normalize_fantasy_command(command) do
    case String.upcase(command) do
      "!OP" -> "OP"
      "!DEOP" -> "DEOP"
      "!VOICE" -> "VOICE"
      "!DEVOICE" -> "DEVOICE"
      _unknown_command -> nil
    end
  end

  @spec handle_service_message(User.t(), String.t(), Message.t()) :: :ok
  defp handle_service_message(user, target_service, message) do
    command_list = extract_command_list(message)
    Service.dispatch(user, target_service, command_list)
  end

  @spec handle_user_message(User.t(), String.t(), String.t(), Message.tags()) :: :ok
  defp handle_user_message(user, target_nick, message_text, message_tags) do
    case Users.get_by_nick(target_nick) do
      {:ok, target_user} -> send_user_message(user, target_user, target_nick, message_text, message_tags)
      {:error, :user_not_found} -> send_remote_user_message(user, target_nick, message_text, message_tags)
    end
  end

  defp send_remote_user_message(user, target_nick, message_text, message_tags) do
    case Directory.get_by_nick(target_nick) do
      {:ok, remote} -> deliver_remote_user_message(user, remote, message_text, message_tags)
      :error -> handle_user_not_found(user, target_nick)
    end
  end

  defp deliver_remote_user_message(user, remote, message_text, message_tags) do
    DirectMessage.send_from_local(user, remote, "PRIVMSG", message_text, message_tags)
  end

  @spec send_user_message(User.t(), User.t(), String.t(), String.t(), Message.tags()) :: :ok
  defp send_user_message(user, target_user, target_nick, message_text, message_tags) do
    cond do
      should_silence_message?(target_user, user) ->
        :ok

      private_ctcp_blocked?(target_user, message_text) ->
        :ok

      :R in target_user.modes and :r not in user.modes ->
        handle_restricted_user_message(user, target_user)

      :g in target_user.modes and
          is_nil(UserAccepts.get_by_user_pid_and_accepted_user_pid(target_user.pid, user.pid)) ->
        handle_blocked_user_message(user, target_user)

      true ->
        handle_normal_user_message(user, target_user, target_nick, message_text, message_tags)
    end
  end

  @spec handle_restricted_user_message(User.t(), User.t()) :: :ok
  defp handle_restricted_user_message(sender, recipient) do
    %Message{
      command: :err_needreggednick,
      params: [sender.nick, recipient.nick],
      trailing: "You must be identified to message this user"
    }
    |> Dispatcher.broadcast(:server, sender)
  end

  @spec handle_blocked_user_message(User.t(), User.t()) :: :ok
  defp handle_blocked_user_message(sender, recipient) do
    %Message{
      command: :rpl_umodegmsg,
      params: [sender.nick, recipient.nick],
      trailing: "Your message has been blocked. #{recipient.nick} is only accepting messages from authorized users."
    }
    |> Dispatcher.broadcast(:server, sender)
  end

  @spec handle_normal_user_message(User.t(), User.t(), String.t(), String.t(), %{
          optional(String.t()) => String.t() | nil
        }) :: :ok
  defp handle_normal_user_message(user, target_user, target_nick, message_text, message_tags) do
    %Message{command: "PRIVMSG", params: [target_nick], trailing: message_text, tags: message_tags}
    |> Dispatcher.broadcast_with_echo(user, target_user)

    if target_user.away_message do
      %Message{command: :rpl_away, params: [user.nick, target_user.nick], trailing: target_user.away_message}
      |> Dispatcher.broadcast(:server, user)
    end

    :ok
  end

  @spec handle_user_not_found(User.t(), String.t()) :: :ok
  defp handle_user_not_found(user, target_nick) do
    %Message{command: :err_nosuchnick, params: [user.nick, target_nick], trailing: "No such nick"}
    |> Dispatcher.broadcast(:server, user)
  end

  # Extracts the message text from a PRIVMSG message
  # This function handles two different formats:
  # 1. Standard IRC format: trailing message
  # 2. Alternative client format: message in params
  @spec extract_message_text(Message.t()) :: String.t()
  defp extract_message_text(%{trailing: trailing}) when trailing != nil, do: trailing
  defp extract_message_text(%{params: [_ | rest_params]}) when rest_params != [], do: Enum.join(rest_params, " ")

  # Extracts the command list from a PRIVMSG message
  # This function handles two different formats:
  # 1. Standard IRC format: splits the trailing message into a list of words
  # 2. Alternative client format: uses the params list directly
  @spec extract_command_list(Message.t()) :: [String.t()]
  defp extract_command_list(%{trailing: trailing}) when trailing != nil, do: String.split(trailing, " ")
  defp extract_command_list(%{params: [_ | rest_params]}) when rest_params != [], do: rest_params
end
