defmodule ElixIRCd.Commands.Invite do
  @moduledoc """
  This module defines the INVITE command.

  INVITE allows channel members to invite users to join a channel. On an
  invite-only channel, only channel operators may issue invitations.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [channel_name?: 1, user_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
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
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "INVITE", params: []}) do
    user
    |> invite_list_messages()
    |> Enum.each(&Dispatcher.broadcast(&1, :server, user))
  end

  @impl true
  def handle(user, %{command: "INVITE", params: [_target_nick]}) do
    %Message{command: :err_needmoreparams, params: [user.nick, "INVITE"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "INVITE", params: [first, second | _rest]}) do
    if legacy_order_enabled?() and channel_name?(first) do
      handle_legacy_order(user, first, second)
    else
      handle_modern_order(user, first, second)
    end
  end

  defp handle_modern_order(user, target_nick, channel_name) do
    with {:ok, target_user} <- get_target_user(target_nick),
         {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, user_channel} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name),
         :ok <- check_user_permission(user_channel, channel),
         :ok <- check_target_user_on_channel(target_user, channel) do
      add_channel_invite(user, target_user, channel)
      send_user_invite_success(user, target_user, channel)
    else
      {:error, error} -> send_user_invite_error(error, user, target_nick, channel_name)
    end
  end

  defp handle_legacy_order(user, channel_name, target_nick) do
    case get_target_user(target_nick) do
      {:ok, target_user} ->
        %Message{command: "INVITE", params: [channel_name, target_user.nick]}
        |> Dispatcher.broadcast(user, [user, target_user])

      {:error, error} ->
        send_user_invite_error(error, user, target_nick, channel_name)
    end
  end

  defp legacy_order_enabled? do
    Application.fetch_env!(:elixircd, :compatibility)[:legacy_invite_order]
  end

  @spec get_target_user(String.t()) :: {:ok, User.t()} | {:error, :target_user_not_found}
  defp get_target_user(target_nick) do
    case Users.get_by_nick(target_nick) do
      {:ok, target_user} -> {:ok, target_user}
      {:error, :user_not_found} -> {:error, :target_user_not_found}
    end
  end

  @spec check_user_permission(UserChannel.t(), Channel.t()) :: :ok | {:error, :user_is_not_operator}
  defp check_user_permission(user_channel, channel) do
    if :i not in channel.modes or :o in user_channel.modes do
      :ok
    else
      {:error, :user_is_not_operator}
    end
  end

  @spec check_target_user_on_channel(User.t(), Channel.t()) :: :ok | {:error, :user_already_on_channel}
  defp check_target_user_on_channel(target_user, channel) do
    case UserChannels.get_by_user_pid_and_channel_name(target_user.pid, channel.name) do
      {:ok, _target_user_channel} -> {:error, :user_already_on_channel}
      {:error, :user_channel_not_found} -> :ok
    end
  end

  @spec add_channel_invite(User.t(), User.t(), Channel.t()) :: :ok
  defp add_channel_invite(user, target_user, channel) do
    ChannelInvites.create(%{user_pid: target_user.pid, channel_name_key: channel.name_key, setter: user_mask(user)})
    :ok
  end

  @spec invite_list_messages(User.t()) :: [Message.t()]
  defp invite_list_messages(user) do
    invite_messages =
      user.pid
      |> ChannelInvites.get_by_user_pid()
      |> Enum.flat_map(fn invite ->
        case Channels.get_by_name(invite.channel_name_key) do
          {:ok, channel} -> [%Message{command: :rpl_invitelist, params: [user.nick, channel.name]}]
          {:error, :channel_not_found} -> []
        end
      end)

    invite_messages ++
      [%Message{command: :rpl_endofinvitelist, params: [user.nick], trailing: "End of /INVITE list"}]
  end

  @spec send_user_invite_success(User.t(), User.t(), Channel.t()) :: :ok
  defp send_user_invite_success(user, target_user, channel) do
    if target_user.away_message do
      %Message{command: :rpl_away, params: [user.nick, target_user.nick], trailing: target_user.away_message}
      |> Dispatcher.broadcast(:server, user)
    end

    %Message{command: :rpl_inviting, params: [user.nick, target_user.nick, channel.name]}
    |> Dispatcher.broadcast(:server, user)

    # Send INVITE to the target user
    %Message{command: "INVITE", params: [target_user.nick, channel.name]}
    |> Dispatcher.broadcast(user, target_user)

    # Send INVITE notification to channel members with invite-notify capability
    send_invite_notify_to_channel_members(user, target_user, channel)
  end

  @spec send_invite_notify_to_channel_members(User.t(), User.t(), Channel.t()) :: :ok
  defp send_invite_notify_to_channel_members(inviter, invitee, channel) do
    user_channels = UserChannels.get_by_channel_name(channel.name)
    user_pids = Enum.map(user_channels, & &1.user_pid)
    users = Users.get_by_pids(user_pids)

    users_with_invite_notify =
      Enum.filter(users, fn u -> "invite-notify" in u.capabilities end)

    unless Enum.empty?(users_with_invite_notify) do
      %Message{command: "INVITE", params: [invitee.nick, channel.name]}
      |> Dispatcher.broadcast(inviter, users_with_invite_notify)
    end

    :ok
  end

  @spec send_user_invite_error(invite_errors(), User.t(), String.t(), String.t()) :: :ok
  defp send_user_invite_error(:target_user_not_found, user, target_nick, _channel_name) do
    %Message{command: :err_nosuchnick, params: [user.nick, target_nick], trailing: "No such nick/channel"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_user_invite_error(:channel_not_found, user, _target_nick, channel_name) do
    %Message{command: :err_nosuchchannel, params: [user.nick, channel_name], trailing: "No such channel"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_user_invite_error(:user_channel_not_found, user, _target_nick, channel_name) do
    %Message{command: :err_notonchannel, params: [user.nick, channel_name], trailing: "You're not on that channel"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_user_invite_error(:user_is_not_operator, user, _target_nick, channel_name) do
    %Message{command: :err_chanoprivsneeded, params: [user.nick, channel_name], trailing: "You're not channel operator"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_user_invite_error(:user_already_on_channel, user, target_nick, channel_name) do
    %Message{
      command: :err_useronchannel,
      params: [user.nick, target_nick, channel_name],
      trailing: "is already on channel"
    }
    |> Dispatcher.broadcast(:server, user)
  end
end
