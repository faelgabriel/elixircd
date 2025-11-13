defmodule ElixIRCd.Commands.Privmsg do
  @moduledoc """
  This module defines the PRIVMSG command.

  PRIVMSG sends a private message to a user, channel, or service.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.MessageFilter, only: [should_silence_message?: 2]
  import ElixIRCd.Utils.MessageText, only: [contains_formatting?: 1, ctcp_message?: 1]

  import ElixIRCd.Utils.Protocol,
    only: [channel_name?: 1, channel_operator?: 1, channel_voice?: 1, service_name?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserAccepts
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Service
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "PRIVMSG"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "PRIVMSG", params: [target | _], trailing: trailing} = message)
      # Handle PRIVMSG when either:
      # 1. A trailing message is provided (standard IRC format)
      # 2. The message is included in params (alternative client format)
      # The extract_message_text/1 function normalizes these different formats
      when trailing != nil or length(message.params) > 1 do
    message_text = extract_message_text(message)

    cond do
      channel_name?(target) -> handle_channel_message(user, target, message_text)
      service_name?(target) -> handle_service_message(user, target, message)
      true -> handle_user_message(user, target, message_text)
    end
  end

  def handle(user, %{command: "PRIVMSG"}) do
    %Message{command: :err_needmoreparams, params: [user.nick, "PRIVMSG"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_channel_message(User.t(), String.t(), String.t()) :: :ok
  defp handle_channel_message(user, channel_name, message_text) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         :ok <- check_user_channel_modes(channel, user),
         :ok <- check_ctcp(channel, user, message_text),
         :ok <- check_formatting(channel, user, message_text) do
      channel_users_without_user =
        UserChannels.get_by_channel_name(channel.name)
        |> Enum.reject(&(&1.user_pid == user.pid))

      user_pids = Enum.map(channel_users_without_user, & &1.user_pid)
      users = Users.get_by_pids(user_pids)

      %Message{command: "PRIVMSG", params: [channel.name], trailing: message_text}
      |> Dispatcher.broadcast(user, users)
    else
      {:error, :channel_not_found} ->
        %Message{command: :err_nosuchchannel, params: [user.nick, channel_name], trailing: "No such channel"}
        |> Dispatcher.broadcast(:server, user)

      {:error, :delay_message_blocked, delay} ->
        %Message{
          command: "937",
          params: [user.nick, channel_name],
          trailing: "You must wait #{delay} seconds after joining before speaking in this channel."
        }
        |> Dispatcher.broadcast(:server, user)

      {:error, :user_can_not_send} ->
        %Message{command: :err_cannotsendtochan, params: [user.nick, channel_name], trailing: "Cannot send to channel"}
        |> Dispatcher.broadcast(:server, user)

      {:error, :ctcp_blocked} ->
        %Message{command: "404", params: [user.nick, channel_name], trailing: "Cannot send CTCP to channel (+C)"}
        |> Dispatcher.broadcast(:server, user)

      {:error, :formatting_blocked} ->
        %Message{
          command: "404",
          params: [user.nick, channel_name],
          trailing: "Cannot send to channel (+c - no colors allowed)"
        }
        |> Dispatcher.broadcast(:server, user)
    end
  end

  @spec handle_service_message(User.t(), String.t(), Message.t()) :: :ok
  defp handle_service_message(user, target_service, message) do
    command_list = extract_command_list(message)
    Service.dispatch(user, target_service, command_list)
  end

  @spec handle_user_message(User.t(), String.t(), String.t()) :: :ok
  defp handle_user_message(user, target_nick, message_text) do
    case Users.get_by_nick(target_nick) do
      {:ok, target_user} -> handle_user_message(user, target_user, target_nick, message_text)
      {:error, :user_not_found} -> handle_user_not_found(user, target_nick)
    end
  end

  @spec handle_user_message(User.t(), User.t(), String.t(), String.t()) :: :ok
  defp handle_user_message(user, target_user, target_nick, message_text) do
    cond do
      should_silence_message?(target_user, user) ->
        :ok

      "R" in target_user.modes and "r" not in user.modes ->
        handle_restricted_user_message(user, target_user)

      "g" in target_user.modes and
          is_nil(UserAccepts.get_by_user_pid_and_accepted_user_pid(target_user.pid, user.pid)) ->
        handle_blocked_user_message(user, target_user)

      true ->
        handle_normal_user_message(user, target_user, target_nick, message_text)
    end
  end

  @spec handle_restricted_user_message(User.t(), User.t()) :: :ok
  defp handle_restricted_user_message(sender, recipient) do
    %Message{
      command: :err_cannotsendtouser,
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

  @spec handle_normal_user_message(User.t(), User.t(), String.t(), String.t()) :: :ok
  defp handle_normal_user_message(user, target_user, target_nick, message_text) do
    %Message{command: "PRIVMSG", params: [target_nick], trailing: message_text}
    |> Dispatcher.broadcast(user, target_user)

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

  @spec check_user_channel_modes(Channel.t(), User.t()) ::
          :ok | {:error, :user_can_not_send} | {:error, :delay_message_blocked, integer()}
  defp check_user_channel_modes(channel, user) do
    with true <- "m" in channel.modes or "n" in channel.modes,
         {:ok, user_channel} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name),
         :ok <- check_channel_moderated(channel, user_channel),
         :ok <- check_delay_message(channel, user_channel) do
      :ok
    else
      # neither m nor n mode
      false -> :ok
      # m or n is set and user is not in the channel
      {:error, :user_channel_not_found} -> {:error, :user_can_not_send}
      # m is set and user is not voice or higher
      {:error, :user_can_not_send} -> {:error, :user_can_not_send}
      # user just joined the channel and needs to wait before sending messages
      {:error, :delay_message_blocked, delay} -> {:error, :delay_message_blocked, delay}
    end
  end

  @spec check_channel_moderated(Channel.t(), UserChannel.t()) :: :ok | {:error, :user_can_not_send}
  defp check_channel_moderated(channel, user_channel) do
    if "m" in channel.modes and not (channel_operator?(user_channel) or channel_voice?(user_channel)) do
      {:error, :user_can_not_send}
    else
      :ok
    end
  end

  @spec check_ctcp(Channel.t(), User.t(), String.t()) :: :ok | {:error, :ctcp_blocked}
  defp check_ctcp(channel, user, message_text) do
    if "C" in channel.modes and ctcp_message?(message_text) and not user_can_send_ctcp?(channel, user) do
      {:error, :ctcp_blocked}
    else
      :ok
    end
  end

  @spec user_can_send_ctcp?(Channel.t(), User.t()) :: boolean()
  defp user_can_send_ctcp?(channel, user) do
    case UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name) do
      {:ok, user_channel} -> channel_operator?(user_channel) or channel_voice?(user_channel)
      {:error, :user_channel_not_found} -> false
    end
  end

  @spec check_formatting(Channel.t(), User.t(), String.t()) :: :ok | {:error, :formatting_blocked}
  defp check_formatting(channel, _user, message_text) do
    if "c" in channel.modes and contains_formatting?(message_text) do
      {:error, :formatting_blocked}
    else
      :ok
    end
  end

  @spec check_delay_message(Channel.t(), UserChannel.t()) :: :ok | {:error, :delay_message_blocked, integer()}
  defp check_delay_message(%{modes: modes}, user_channel) do
    with delay when is_integer(delay) <- extract_delay_mode_value(modes),
         false <- channel_operator?(user_channel) or channel_voice?(user_channel),
         false <- enough_delay_time_passed?(user_channel, delay) do
      {:error, :delay_message_blocked, delay}
    else
      _ -> :ok
    end
  end

  @spec extract_delay_mode_value([{String.t(), String.t()}]) :: integer() | nil
  defp extract_delay_mode_value(modes) do
    Enum.find_value(modes, fn
      {"d", value} -> String.to_integer(value)
      _ -> nil
    end)
  end

  @spec enough_delay_time_passed?(UserChannel.t(), integer()) :: boolean()
  defp enough_delay_time_passed?(user_channel, delay) do
    join_time = DateTime.to_unix(user_channel.created_at, :second)
    now = DateTime.to_unix(DateTime.utc_now(), :second)
    now >= join_time + delay
  end
end
