defmodule ElixIRCd.Commands.Kick do
  @moduledoc """
  This module defines the KICK command.

  KICK allows channel operators to remove users from a channel.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.MessageFilter, only: [filter_auditorium_users: 3]
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.ChannelDirectory
  alias ElixIRCd.ServerLink.ChannelView
  alias ElixIRCd.ServerLink.Directory
  alias ElixIRCd.ServerLink.Hub
  alias ElixIRCd.ServerLink.KickMutation
  alias ElixIRCd.ServerLink.KickMutation.Outbound
  alias ElixIRCd.ServerLink.RemoteUser
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelIdentity
  alias ElixIRCd.Tables.ChannelKickMarker
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.Targets

  @type kick_errors ::
          :channel_not_found
          | :user_channel_not_found
          | :user_is_not_operator
          | :target_user_not_found
          | :target_user_channel_not_found
          | :kick_message_too_long
          | :network_directory_unavailable

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "KICK"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "KICK", params: params}) when length(params) < 2 do
    %Message{command: :err_needmoreparams, params: [user.nick, "KICK"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "KICK", params: [channel_names, target_nicks | _rest], trailing: reason}) do
    case target_pairs(channel_names, target_nicks) do
      {:ok, pairs} ->
        Enum.each(pairs, fn {channel_name, target_nick} -> kick_target(user, channel_name, target_nick, reason) end)

      {:error, :mismatched_targets} ->
        send_need_more_params(user)
    end

    :ok
  end

  @spec target_pairs(String.t(), String.t()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, :mismatched_targets}
  defp target_pairs(channel_names, target_nicks) do
    channels = Targets.split("KICK", channel_names)
    users = Targets.split("KICK", target_nicks)

    cond do
      length(channels) == length(users) -> {:ok, Enum.zip(channels, users)}
      length(channels) == 1 -> {:ok, Enum.map(users, &{hd(channels), &1})}
      length(users) == 1 -> {:ok, Enum.map(channels, &{&1, hd(users)})}
      true -> {:error, :mismatched_targets}
    end
  end

  @spec kick_target(User.t(), String.t(), String.t(), String.t() | nil) :: :ok
  defp kick_target(user, channel_name, target_nick, reason) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, user_channel} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name),
         :ok <- check_user_permission(user_channel),
         :ok <- check_network_identity(channel),
         :ok <- check_message_length(reason) do
      case locate_target(target_nick) do
        {:ok, %User{} = target_user} -> kick_local_target(channel, user, target_user, reason)
        {:remote, %RemoteUser{} = remote} -> kick_remote_target(channel, user, remote, reason)
        {:error, error} -> send_user_kick_error(error, user, channel_name, target_nick)
      end
    else
      {:error, error} -> send_user_kick_error(error, user, channel_name, target_nick)
    end
  end

  defp kick_local_target(channel, user, target_user, reason) do
    case get_target_user_channel(target_user, channel) do
      {:ok, target_user_channel} ->
        user_channels =
          UserChannels.get_by_channel_name(channel.name)
          |> filter_auditorium_users(target_user_channel, channel.modes)

        mark_network_kick(channel, user, target_user, target_user_channel, reason)
        UserChannels.delete(target_user_channel)
        send_user_kick_success(channel, user, target_user, reason, user_channels)

      {:error, error} ->
        send_user_kick_error(error, user, channel.name, target_user.nick)
    end
  end

  defp kick_remote_target(channel, user, remote, reason) do
    with :ok <- check_remote_registration(channel),
         {:ok, %ChannelView{remote_members: members}} <- ChannelDirectory.get(channel.name),
         true <- Enum.any?(members, &(&1.origin == remote.origin and &1.member["uid"] == remote.uid)) do
      request = %Outbound{
        sender_pid: user.pid,
        target_origin: remote.origin,
        target_uid: remote.uid,
        target_nick: remote.user["nick"],
        channel: channel.name,
        reason: reason || user.nick
      }

      Observability.defer_effect(fn ->
        dispatch_kick_request(request)
      end)
    else
      {:error, :network_directory_unavailable} ->
        send_user_kick_error(:network_directory_unavailable, user, channel.name, remote.user["nick"])

      _ ->
        send_user_kick_error(:target_user_channel_not_found, user, channel.name, remote.user["nick"])
    end
  end

  defp check_remote_registration(channel) do
    case RegisteredChannels.get_by_name(channel.name) do
      {:ok, _registered} -> {:error, :network_directory_unavailable}
      {:error, :registered_channel_not_found} -> :ok
    end
  end

  defp dispatch_kick_request(%Outbound{} = request) do
    if Hub.request_kick(request) == :unavailable,
      do: KickMutation.reply(request.sender_pid, request.channel, request.target_nick, "stale_channel")
  end

  @spec send_need_more_params(User.t()) :: :ok
  defp send_need_more_params(user) do
    %Message{command: :err_needmoreparams, params: [user.nick, "KICK"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec check_user_permission(UserChannel.t()) :: :ok | {:error, :user_is_not_operator}
  defp check_user_permission(user_channel) do
    if :o in user_channel.modes do
      :ok
    else
      {:error, :user_is_not_operator}
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
        creator == selected["creator"] and DateTime.compare(channel.created_at, timestamp) == :eq

      _ ->
        false
    end
  end

  defp mark_network_kick(channel, actor, target, membership, reason) do
    if Application.fetch_env!(:elixircd, :server_links)[:enabled] do
      origin = Application.fetch_env!(:elixircd, :server)[:hostname]

      channel.name_key
      |> ChannelKickMarker.local(
        target.pid,
        membership.created_at,
        actor.pid,
        origin,
        user_mask(actor),
        reason || actor.nick
      )
      |> Memento.Query.write()
    end

    :ok
  end

  @spec check_message_length(String.t() | nil) :: :ok | {:error, :kick_message_too_long}
  defp check_message_length(nil), do: :ok

  defp check_message_length(reason) do
    max_kick_message_length = Application.fetch_env!(:elixircd, :channel)[:max_kick_message_length]

    if String.length(reason) > max_kick_message_length do
      {:error, :kick_message_too_long}
    else
      :ok
    end
  end

  defp locate_target(target_nick) do
    local = Users.get_by_nick(target_nick)

    if Application.fetch_env!(:elixircd, :server_links)[:enabled] do
      case {local, Directory.lookup_by_nick(target_nick)} do
        {{:ok, _user}, {:ok, _remote}} -> {:error, :network_directory_unavailable}
        {_local, {:ok, remote}} -> {:remote, remote}
        {{:ok, user}, :error} -> {:ok, user}
        {{:error, :user_not_found}, :error} -> {:error, :target_user_not_found}
        {_local, :unavailable} -> {:error, :network_directory_unavailable}
      end
    else
      case local do
        {:ok, user} -> {:ok, user}
        {:error, :user_not_found} -> {:error, :target_user_not_found}
      end
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
    user_pids = Enum.map(user_channels, & &1.user_pid)
    users = Users.get_by_pids(user_pids)

    %Message{command: "KICK", params: [channel.name, target_user.nick], trailing: reason || user.nick}
    |> Dispatcher.broadcast(user, users)
  end

  @spec send_user_kick_error(kick_errors(), User.t(), String.t(), String.t()) :: :ok
  defp send_user_kick_error(:channel_not_found, user, channel_name, _target_nick) do
    %Message{command: :err_nosuchchannel, params: [user.nick, channel_name], trailing: "No such channel"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_user_kick_error(:user_channel_not_found, user, channel_name, _target_nick) do
    %Message{command: :err_notonchannel, params: [user.nick, channel_name], trailing: "You're not on that channel"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_user_kick_error(:user_is_not_operator, user, channel_name, _target_nick) do
    %Message{command: :err_chanoprivsneeded, params: [user.nick, channel_name], trailing: "You're not channel operator"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_user_kick_error(:kick_message_too_long, user, channel_name, _target_nick) do
    max_kick_message_length = Application.fetch_env!(:elixircd, :channel)[:max_kick_message_length]

    %Message{
      command: :err_inputtoolong,
      params: [user.nick, channel_name],
      trailing: "Kick reason too long (maximum length is #{max_kick_message_length} characters)"
    }
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_user_kick_error(:target_user_not_found, user, _channel_name, target_nick) do
    %Message{command: :err_nosuchnick, params: [user.nick, target_nick], trailing: "No such nick/channel"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_user_kick_error(:target_user_channel_not_found, user, channel_name, _target_nick) do
    %Message{command: :err_usernotinchannel, params: [user.nick, channel_name], trailing: "They aren't on that channel"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_user_kick_error(:network_directory_unavailable, user, channel_name, _target_nick) do
    %Message{
      command: :err_unavailresource,
      params: [user.nick, channel_name],
      trailing: "Channel membership is temporarily unavailable on this network"
    }
    |> Dispatcher.broadcast(:server, user)
  end
end
