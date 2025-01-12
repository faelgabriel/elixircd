defmodule ElixIRCd.Command.Kick do
  @moduledoc """
  This module defines the KICK command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Helper, only: [get_user_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Channels
  alias ElixIRCd.Repository.UserChannels
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @type kick_errors ::
          :channel_not_found
          | :user_channel_not_found
          | :user_is_not_operator
          | :target_user_not_found
          | :target_user_channel_not_found

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "KICK"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "KICK", params: params}) when length(params) < 2 do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "KICK"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  def handle(user, %{command: "KICK", params: [channel_name, target_nick | _rest], trailing: reason}) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, user_channel} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name),
         :ok <- check_user_permission(user_channel),
         {:ok, target_user} <- get_target_user(target_nick),
         {:ok, target_user_channel} <- get_target_user_channel(target_user, channel) do
      user_channels = UserChannels.get_by_channel_name(channel.name)
      UserChannels.delete(target_user_channel)

      send_user_kick_success(channel, user, target_user, reason, user_channels)
    else
      {:error, error} -> send_user_kick_error(error, user, channel_name, target_nick)
    end
  end

  @spec check_user_permission(UserChannel.t()) :: :ok | {:error, :user_is_not_operator}
  defp check_user_permission(user_channel) do
    if "o" in user_channel.modes do
      :ok
    else
      {:error, :user_is_not_operator}
    end
  end

  @spec get_target_user(String.t()) :: {:ok, User.t()} | {:error, :target_user_not_found}
  defp get_target_user(target_nick) do
    case Users.get_by_nick(target_nick) do
      {:ok, target_user} -> {:ok, target_user}
      {:error, :user_not_found} -> {:error, :target_user_not_found}
    end
  end

  @spec get_target_user_channel(User.t(), Channel.t()) ::
          {:ok, UserChannel.t()} | {:error, :target_user_channel_not_found}
  defp get_target_user_channel(target_user, channel) do
    case UserChannels.get_by_user_pid_and_channel_name(target_user.pid, channel.name) do
      {:ok, target_user_channel} -> {:ok, target_user_channel}
      {:error, :user_channel_not_found} -> {:error, :target_user_channel_not_found}
    end
  end

  @spec send_user_kick_success(Channel.t(), User.t(), User.t(), String.t(), [UserChannel.t()]) :: :ok
  defp send_user_kick_success(channel, user, target_user, reason, user_channels) do
    Message.build(%{
      prefix: get_user_mask(user),
      command: "KICK",
      params: [channel.name, target_user.nick],
      trailing: reason
    })
    |> Messaging.broadcast(user_channels)
  end

  @spec send_user_kick_error(kick_errors(), User.t(), String.t(), String.t()) :: :ok
  defp send_user_kick_error(:channel_not_found, user, channel_name, _target_nick) do
    Message.build(%{
      prefix: :server,
      command: :err_nosuchchannel,
      params: [user.nick, channel_name],
      trailing: "No such channel"
    })
    |> Messaging.broadcast(user)
  end

  defp send_user_kick_error(:user_channel_not_found, user, channel_name, _target_nick) do
    Message.build(%{
      prefix: :server,
      command: :err_usernotinchannel,
      params: [user.nick, channel_name],
      trailing: "You're not on that channel"
    })
    |> Messaging.broadcast(user)
  end

  defp send_user_kick_error(:user_is_not_operator, user, channel_name, _target_nick) do
    Message.build(%{
      prefix: :server,
      command: :err_chanoprivsneeded,
      params: [user.nick, channel_name],
      trailing: "You're not channel operator"
    })
    |> Messaging.broadcast(user)
  end

  defp send_user_kick_error(:target_user_not_found, user, _channel_name, target_nick) do
    Message.build(%{
      prefix: :server,
      command: :err_nosuchnick,
      params: [user.nick, target_nick],
      trailing: "No such nick/channel"
    })
    |> Messaging.broadcast(user)
  end

  defp send_user_kick_error(:target_user_channel_not_found, user, channel_name, _target_nick) do
    Message.build(%{
      prefix: :server,
      command: :err_usernotinchannel,
      params: [user.nick, channel_name],
      trailing: "They aren't on that channel"
    })
    |> Messaging.broadcast(user)
  end
end
