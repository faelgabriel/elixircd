defmodule ElixIRCd.Command.Invite do
  @moduledoc """
  This module defines the INVITE command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Helper, only: [build_user_mask: 1]

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Channels
  alias ElixIRCd.Repository.UserChannels
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @type invite_errors ::
          :target_user_not_found
          | :channel_not_found
          | :user_channel_not_found
          | :user_is_not_operator
          | :user_already_on_channel

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "INVITE"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "INVITE", params: params}) when length(params) <= 1 do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply, "INVITE"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "INVITE", params: [target_nick, channel_name | _rest]}) do
    with {:ok, target_user} <- get_target_user(target_nick),
         {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, user_channel} <- UserChannels.get_by_user_port_and_channel_name(user.port, channel.name),
         :ok <- check_user_permission(user_channel),
         :ok <- check_target_user_on_channel(target_user, channel) do
      send_user_invite_success(user, target_user, channel)
    else
      {:error, error} -> send_user_invite_error(error, user, target_nick, channel_name)
    end
  end

  @spec get_target_user(String.t()) :: {:ok, User.t()} | {:error, :target_user_not_found}
  defp get_target_user(target_nick) do
    case Users.get_by_nick(target_nick) do
      {:ok, target_user} -> {:ok, target_user}
      {:error, :user_not_found} -> {:error, :target_user_not_found}
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

  @spec check_target_user_on_channel(User.t(), Channel.t()) :: :ok | {:error, :user_already_on_channel}
  defp check_target_user_on_channel(target_user, channel) do
    case UserChannels.get_by_user_port_and_channel_name(target_user.port, channel.name) do
      {:ok, _target_user_channel} -> {:error, :user_already_on_channel}
      {:error, :user_channel_not_found} -> :ok
    end
  end

  @spec send_user_invite_success(User.t(), User.t(), Channel.t()) :: :ok
  defp send_user_invite_success(user, target_user, channel) do
    # Future: check if channel is +i and add a ChannelInvite
    # Future: if mode is +i and is changed to -i, remove all ChannelInvites
    # Future: maybe handle RPL_AWAY
    Message.build(%{
      prefix: :server,
      command: :rpl_inviting,
      params: [user.nick, target_user.nick, channel.name]
    })
    |> Messaging.broadcast(user)

    Message.build(%{
      prefix: build_user_mask(user),
      command: "INVITE",
      params: [target_user.nick, channel.name]
    })
    |> Messaging.broadcast(target_user)
  end

  @spec send_user_invite_error(invite_errors(), User.t(), String.t(), String.t()) :: :ok
  defp send_user_invite_error(:target_user_not_found, user, target_nick, _channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_nosuchnick,
      params: [user.nick, target_nick],
      trailing: "No such nick/channel"
    })
    |> Messaging.broadcast(user)
  end

  defp send_user_invite_error(:channel_not_found, user, _target_nick, channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_nosuchchannel,
      params: [user.nick, channel_name],
      trailing: "No such channel"
    })
    |> Messaging.broadcast(user)
  end

  defp send_user_invite_error(:user_channel_not_found, user, _target_nick, channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_notonchannel,
      params: [user.nick, channel_name],
      trailing: "You're not on that channel"
    })
    |> Messaging.broadcast(user)
  end

  defp send_user_invite_error(:user_is_not_operator, user, _target_nick, channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_chanoprivsneeded,
      params: [user.nick, channel_name],
      trailing: "You're not channel operator"
    })
    |> Messaging.broadcast(user)
  end

  defp send_user_invite_error(:user_already_on_channel, user, target_nick, channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_useronchannel,
      params: [user.nick, target_nick, channel_name],
      trailing: "is already on channel"
    })
    |> Messaging.broadcast(user)
  end
end
