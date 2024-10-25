defmodule ElixIRCd.Command.Privmsg do
  @moduledoc """
  This module defines the PRIVMSG command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Helper, only: [get_user_mask: 1, channel_name?: 1, channel_operator?: 1, channel_voice?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Channels
  alias ElixIRCd.Repository.UserChannels
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "PRIVMSG"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "PRIVMSG", params: []}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "PRIVMSG"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "PRIVMSG", trailing: nil}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "PRIVMSG"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "PRIVMSG", params: [target], trailing: message_text}) do
    if channel_name?(target),
      do: handle_channel_message(user, target, message_text),
      else: handle_user_message(user, target, message_text)
  end

  @spec handle_channel_message(User.t(), String.t(), String.t()) :: :ok
  defp handle_channel_message(user, channel_name, message_text) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         :ok <- check_channel_modes(channel, user) do
      channel_users_without_user =
        UserChannels.get_by_channel_name(channel.name)
        |> Enum.reject(&(&1.user_pid == user.pid))

      Message.build(%{prefix: get_user_mask(user), command: "PRIVMSG", params: [channel.name], trailing: message_text})
      |> Messaging.broadcast(channel_users_without_user)
    else
      {:error, :channel_not_found} ->
        Message.build(%{
          prefix: :server,
          command: :err_nosuchchannel,
          params: [user.nick, channel_name],
          trailing: "No such channel"
        })
        |> Messaging.broadcast(user)

      {:error, :user_can_not_send} ->
        Message.build(%{
          prefix: :server,
          command: :err_cannotsendtochan,
          params: [user.nick, channel_name],
          trailing: "Cannot send to channel"
        })
        |> Messaging.broadcast(user)
    end
  end

  defp handle_user_message(user, target_nick, message_text) do
    case Users.get_by_nick(target_nick) do
      {:ok, target_user} ->
        Message.build(%{
          prefix: get_user_mask(user),
          command: "PRIVMSG",
          params: [target_nick],
          trailing: message_text
        })
        |> Messaging.broadcast(target_user)

        if target_user.away_message do
          Message.build(%{
            prefix: :server,
            command: :rpl_away,
            params: [user.nick, target_user.nick],
            trailing: target_user.away_message
          })
          |> Messaging.broadcast(user)
        end

        :ok

      {:error, _} ->
        Message.build(%{
          prefix: :server,
          command: :err_nosuchnick,
          params: [user.nick, target_nick],
          trailing: "No such nick"
        })
        |> Messaging.broadcast(user)
    end
  end

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
