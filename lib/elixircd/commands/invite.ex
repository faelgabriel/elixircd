defmodule ElixIRCd.Commands.Invite do
  @moduledoc """
  This module defines the INVITE command.

  INVITE allows channel members to invite users to join a channel. On an
  invite-only channel, only channel operators may issue invitations.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [channel_name?: 1, user_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.ChannelInvites
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.Directory
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.InviteMutation
  alias ElixIRCd.ServerLink.InviteMutation.ChannelRef
  alias ElixIRCd.ServerLink.InviteMutation.LocalNotice
  alias ElixIRCd.ServerLink.InviteMutation.Outbound
  alias ElixIRCd.ServerLink.RemoteUser
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelIdentity
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.CaseMapping

  @type invite_errors ::
          :target_user_not_found
          | :channel_not_found
          | :user_channel_not_found
          | :user_is_not_operator
          | :user_already_on_channel
          | :network_directory_unavailable

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
    with {:ok, target_user} <- locate_target(target_nick),
         {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, user_channel} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name),
         :ok <- check_network_identity(channel),
         :ok <- check_user_permission(user_channel, channel) do
      invite_target(user, target_user, channel, user_channel)
    else
      {:error, error} -> send_user_invite_error(error, user, target_nick, channel_name)
    end
  end

  defp invite_target(user, %User{} = target, channel, user_channel) do
    case check_target_user_on_channel(target, channel) do
      :ok ->
        add_channel_invite(user, target, channel, user_channel)
        send_user_invite_success(user, target, channel)
        announce_local_invite(user, target, channel)

      {:error, error} ->
        send_user_invite_error(error, user, target.nick, channel.name)
    end
  end

  defp invite_target(user, %RemoteUser{} = target, channel, _user_channel) do
    with :ok <- check_remote_registration(channel),
         :ok <- check_remote_target_membership(channel, target) do
      request = %Outbound{
        sender_pid: user.pid,
        target_origin: target.origin,
        target_uid: target.uid,
        target_nick: target.user["nick"],
        channel: channel.name
      }

      Observability.defer_effect(fn -> dispatch_remote_invite(request) end)
    else
      {:error, error} -> send_user_invite_error(error, user, target.user["nick"], channel.name)
    end
  end

  defp announce_local_invite(user, target, channel) do
    if Application.fetch_env!(:elixircd, :server_links)[:enabled] do
      local_id = Application.fetch_env!(:elixircd, :server)[:hostname]

      creator =
        case Memento.Query.read(ChannelIdentity, channel.name_key) do
          %ChannelIdentity{creator: creator} -> creator
          nil -> local_id
        end

      notice = %LocalNotice{
        sender_pid: user.pid,
        sender_mask: user_mask(user),
        sender_account: user.identified_as,
        target_pid: target.pid,
        target_nick: target.nick,
        channel: channel.name,
        channel_ref: %ChannelRef{creator: creator, created_at: DateTime.to_iso8601(channel.created_at)}
      }

      Observability.defer_effect(fn -> Hub.announce_invite(notice) end)
    end

    :ok
  end

  defp dispatch_remote_invite(%Outbound{} = request) do
    if Hub.request_invite(request) == :unavailable,
      do: InviteMutation.reply(request.sender_pid, request.channel, request.target_nick, "stale_channel")
  end

  defp check_remote_registration(channel) do
    case RegisteredChannels.get_by_name(channel.name) do
      {:ok, _registered} -> {:error, :network_directory_unavailable}
      {:error, :registered_channel_not_found} -> :ok
    end
  end

  defp check_remote_target_membership(channel, target) do
    case ChannelDirectory.get(channel.name) do
      {:ok, %ChannelView{remote_members: members}} ->
        if Enum.any?(members, &(&1.origin == target.origin and &1.member["uid"] == target.uid)),
          do: {:error, :user_already_on_channel},
          else: :ok

      _ ->
        {:error, :network_directory_unavailable}
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

  defp locate_target(target_nick) do
    local = Users.get_by_nick(target_nick)

    if Application.fetch_env!(:elixircd, :server_links)[:enabled] do
      case {local, Directory.lookup_by_nick(target_nick)} do
        {{:ok, _user}, {:ok, _remote}} -> {:error, :network_directory_unavailable}
        {_local, {:ok, remote}} -> {:ok, remote}
        {{:ok, user}, :error} -> {:ok, user}
        {{:error, :user_not_found}, :error} -> {:error, :target_user_not_found}
        {_local, :unavailable} -> {:error, :network_directory_unavailable}
      end
    else
      get_target_user(target_nick)
    end
  end

  defp check_network_identity(channel) do
    if Application.fetch_env!(:elixircd, :server_links)[:enabled] do
      check_linked_network_identity(channel)
    else
      :ok
    end
  end

  defp check_linked_network_identity(channel) do
    case ChannelDirectory.get(channel.name) do
      {:ok, %ChannelView{channel: selected}} ->
        if same_network_identity?(channel, selected), do: :ok, else: {:error, :network_directory_unavailable}

      _ ->
        {:error, :network_directory_unavailable}
    end
  end

  defp same_network_identity?(channel, selected) do
    local_id = Application.fetch_env!(:elixircd, :server)[:hostname]

    creator =
      case Memento.Query.read(ChannelIdentity, channel.name_key) do
        %ChannelIdentity{creator: creator} -> creator
        nil -> local_id
      end

    case DateTime.from_iso8601(selected["created_at"]) do
      {:ok, timestamp, _offset} ->
        creator == selected["creator"] and DateTime.compare(channel.created_at, timestamp) == :eq and
          CaseMapping.normalize(selected["name"]) == channel.name_key

      _ ->
        false
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

  @spec add_channel_invite(User.t(), User.t(), Channel.t(), UserChannel.t()) :: :ok
  defp add_channel_invite(user, target_user, channel, user_channel) do
    existing_bypass? =
      case ChannelInvites.get_by_user_pid_and_channel_name(target_user.pid, channel.name) do
        {:ok, invite} -> invite.bypass_ban == true
        {:error, :channel_invite_not_found} -> false
      end

    ChannelInvites.create(%{
      user_pid: target_user.pid,
      channel_name_key: channel.name_key,
      setter: user_mask(user),
      bypass_ban: :o in user_channel.modes or existing_bypass?
    })

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
          {:error, :channel_not_found} -> remote_invite_list_entry(user, invite.channel_name_key)
        end
      end)

    invite_messages ++
      [%Message{command: :rpl_endofinvitelist, params: [user.nick], trailing: "End of /INVITE list"}]
  end

  defp remote_invite_list_entry(user, channel_key) do
    if Application.fetch_env!(:elixircd, :server_links)[:enabled] do
      case ChannelDirectory.get(channel_key) do
        {:ok, %ChannelView{channel: %{"name" => name}}} ->
          [%Message{command: :rpl_invitelist, params: [user.nick, name]}]

        _ ->
          []
      end
    else
      []
    end
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

  defp send_user_invite_error(:network_directory_unavailable, user, _target_nick, channel_name) do
    %Message{
      command: :err_unavailresource,
      params: [user.nick, channel_name],
      trailing: "Channel invitations are temporarily unavailable on this network"
    }
    |> Dispatcher.broadcast(:server, user)
  end
end
