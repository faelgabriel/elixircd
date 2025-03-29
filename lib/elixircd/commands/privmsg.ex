defmodule ElixIRCd.Commands.Privmsg do
  @moduledoc """
  This module defines the PRIVMSG command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol,
    only: [user_mask: 1, channel_name?: 1, channel_operator?: 1, channel_voice?: 1, service_name?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
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
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  def handle(user, %{command: "PRIVMSG", params: [target | _], trailing: trailing} = message)
      # Handle PRIVMSG when either:
      # 1. A trailing message is provided (standard IRC format)
      # 2. The message is included in params (alternative client format)
      # The extract_message_text/1 function normalizes these different formats
      when trailing != nil or length(message.params) > 1 do
    cond do
      channel_name?(target) -> handle_channel_message(user, target, message)
      service_name?(target) -> handle_service_message(user, target, message)
      true -> handle_user_message(user, target, message)
    end
  end

  def handle(user, %{command: "PRIVMSG"}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "PRIVMSG"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end

  @spec handle_channel_message(User.t(), String.t(), Message.t()) :: :ok
  defp handle_channel_message(user, channel_name, message) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         :ok <- check_channel_modes(channel, user) do
      channel_users_without_user =
        UserChannels.get_by_channel_name(channel.name)
        |> Enum.reject(&(&1.user_pid == user.pid))

      message_text = extract_message_text(message)

      Message.build(%{prefix: user_mask(user), command: "PRIVMSG", params: [channel.name], trailing: message_text})
      |> Dispatcher.broadcast(channel_users_without_user)
    else
      {:error, :channel_not_found} ->
        Message.build(%{
          prefix: :server,
          command: :err_nosuchchannel,
          params: [user.nick, channel_name],
          trailing: "No such channel"
        })
        |> Dispatcher.broadcast(user)

      {:error, :user_can_not_send} ->
        Message.build(%{
          prefix: :server,
          command: :err_cannotsendtochan,
          params: [user.nick, channel_name],
          trailing: "Cannot send to channel"
        })
        |> Dispatcher.broadcast(user)
    end
  end

  @spec handle_service_message(User.t(), String.t(), Message.t()) :: :ok
  defp handle_service_message(user, target_service, message) do
    command_list = extract_command_list(message)
    Service.dispatch(user, target_service, command_list)
  end

  @spec handle_user_message(User.t(), String.t(), Message.t()) :: :ok
  defp handle_user_message(user, target_nick, message) do
    case Users.get_by_nick(target_nick) do
      {:ok, target_user} ->
        message_text = extract_message_text(message)

        Message.build(%{prefix: user_mask(user), command: "PRIVMSG", params: [target_nick], trailing: message_text})
        |> Dispatcher.broadcast(target_user)

        if target_user.away_message do
          Message.build(%{
            prefix: :server,
            command: :rpl_away,
            params: [user.nick, target_user.nick],
            trailing: target_user.away_message
          })
          |> Dispatcher.broadcast(user)
        end

        :ok

      {:error, _} ->
        Message.build(%{
          prefix: :server,
          command: :err_nosuchnick,
          params: [user.nick, target_nick],
          trailing: "No such nick"
        })
        |> Dispatcher.broadcast(user)
    end
  end

  # Extracts the message text from a PRIVMSG message
  # This function handles two different formats:
  # 1. Standard IRC format: trailing message
  # 2. Alternative client format: message in params
  @spec extract_message_text(Message.t()) :: String.t()
  defp extract_message_text(%{trailing: trailing}) when trailing != nil, do: trailing
  defp extract_message_text(%{params: [_, rest_params]}) when rest_params != [], do: Enum.join(rest_params, " ")

  # Extracts the command list from a PRIVMSG message
  # This function handles two different formats:
  # 1. Standard IRC format: splits the trailing message into a list of words
  # 2. Alternative client format: uses the params list directly
  @spec extract_command_list(Message.t()) :: [String.t()]
  defp extract_command_list(%{trailing: trailing}) when trailing != nil, do: String.split(trailing, " ")
  defp extract_command_list(%{params: [_, rest_params]}) when rest_params != [], do: rest_params

  @spec check_channel_modes(Channel.t(), User.t()) :: :ok | {:error, :user_can_not_send}
  defp check_channel_modes(channel, user) do
    with true <- "m" in channel.modes or "n" in channel.modes,
         {:ok, user_channel} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name),
         :ok <- check_channel_moderated(channel, user_channel) do
      :ok
    else
      # neither m nor n mode
      false -> :ok
      # user can not send
      {:error, _} -> {:error, :user_can_not_send}
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
end
