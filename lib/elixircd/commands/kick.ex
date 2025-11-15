defmodule ElixIRCd.Commands.Kick do
  @moduledoc """
  This module defines the KICK command.

  KICK allows channel operators to remove users from a channel.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.MessageFilter, only: [filter_auditorium_users: 3]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @type kick_errors ::
          :channel_not_found
          | :user_channel_not_found
          | :user_is_not_operator
          | :target_user_not_found
          | :target_user_channel_not_found
          | :kick_message_too_long

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

  def handle(user, %{command: "KICK", params: [channel_name, target_nick | _rest], trailing: reason}) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, user_channel} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name),
         :ok <- check_user_permission(user_channel),
         :ok <- check_message_length(reason),
         {:ok, target_user} <- get_target_user(target_nick),
         {:ok, target_user_channel} <- get_target_user_channel(target_user, channel) do
      user_channels =
        UserChannels.get_by_channel_name(channel.name)
        |> filter_auditorium_users(target_user_channel, channel.modes)

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

  @spec check_message_length(String.t() | nil) :: :ok | {:error, :kick_message_too_long}
  defp check_message_length(nil), do: :ok

  defp check_message_length(reason) do
    max_kick_message_length = Application.get_env(:elixircd, :channel)[:max_kick_message_length]

    if String.length(reason) > max_kick_message_length do
      {:error, :kick_message_too_long}
    else
      :ok
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
    user_pids = Enum.map(user_channels, & &1.user_pid)
    users = Users.get_by_pids(user_pids)

    %Message{command: "KICK", params: [channel.name, target_user.nick], trailing: reason}
    |> Dispatcher.broadcast(user, users)
  end

  @spec send_user_kick_error(kick_errors(), User.t(), String.t(), String.t()) :: :ok
  defp send_user_kick_error(:channel_not_found, user, channel_name, _target_nick) do
    %Message{command: :err_nosuchchannel, params: [user.nick, channel_name], trailing: "No such channel"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_user_kick_error(:user_channel_not_found, user, channel_name, _target_nick) do
    %Message{command: :err_usernotinchannel, params: [user.nick, channel_name], trailing: "You're not on that channel"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_user_kick_error(:user_is_not_operator, user, channel_name, _target_nick) do
    %Message{command: :err_chanoprivsneeded, params: [user.nick, channel_name], trailing: "You're not channel operator"}
    |> Dispatcher.broadcast(:server, user)
  end

  defp send_user_kick_error(:kick_message_too_long, user, channel_name, _target_nick) do
    max_kick_message_length = Application.get_env(:elixircd, :channel)[:max_kick_message_length]

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
end
