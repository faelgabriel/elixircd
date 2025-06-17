defmodule ElixIRCd.Commands.Mode do
  @moduledoc """
  This module defines the Mode command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [channel_name?: 1, user_mask: 1, channel_operator?: 1]

  alias ElixIRCd.Commands.Mode.ChannelModes
  alias ElixIRCd.Commands.Mode.UserModes
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @type channel_mode_errors :: :channel_not_found | :user_channel_not_found | :user_is_not_operator | :too_many_modes

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "MODE"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "MODE", params: []}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "MODE"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "MODE", params: [target | rest]}) do
    [mode_string, values] =
      case rest do
        [] -> [nil, nil]
        [mode_string | values] -> [mode_string, values]
      end

    case channel_name?(target) do
      true -> handle_channel_mode(user, target, mode_string, values)
      false -> handle_user_mode(user, target, mode_string)
    end
  end

  @spec handle_channel_mode(User.t(), String.t(), String.t() | nil, list(String.t()) | nil) :: :ok
  defp handle_channel_mode(user, channel_name, nil, nil) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, _user_channel} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name) do
      Message.build(%{
        prefix: user_mask(user),
        command: "MODE",
        params: [channel.name, ChannelModes.display_modes(channel.modes)]
      })
      |> Dispatcher.broadcast(user)
    else
      {:error, error} -> send_channel_mode_error(error, user, channel_name)
    end
  end

  defp handle_channel_mode(user, channel_name, mode_string, values) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, user_channel} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name),
         :ok <- check_user_permission(user_channel),
         {validated_modes, invalid_modes} <- ChannelModes.parse_mode_changes(mode_string, values),
         :ok <- validate_mode_limit(validated_modes) do
      {validated_filtered_modes, listing_modes, missing_value_modes} = ChannelModes.filter_mode_changes(validated_modes)

      if length(missing_value_modes) > 0 do
        Message.build(%{
          prefix: :server,
          command: :err_needmoreparams,
          params: [user.nick, "MODE"],
          trailing: "Not enough parameters"
        })
        |> Dispatcher.broadcast(user)
      else
        {updated_channel, applied_changes} = ChannelModes.apply_mode_changes(user, channel, validated_filtered_modes)

        if length(applied_changes) > 0 do
          channel_users = UserChannels.get_by_channel_name(updated_channel.name)

          Message.build(%{
            prefix: user_mask(user),
            command: "MODE",
            params: [updated_channel.name, ChannelModes.display_mode_changes(applied_changes)]
          })
          |> Dispatcher.broadcast(channel_users)
        end

        send_channel_mode_listing(listing_modes, user, updated_channel)
        send_invalid_modes(invalid_modes, user)
      end
    else
      {:error, channel_mode_error} -> send_channel_mode_error(channel_mode_error, user, channel_name)
    end
  end

  @spec check_user_permission(UserChannel.t()) :: :ok | {:error, :user_is_not_operator}
  defp check_user_permission(user_channel) do
    case channel_operator?(user_channel) do
      true -> :ok
      false -> {:error, :user_is_not_operator}
    end
  end

  @spec validate_mode_limit([ChannelModes.mode_change()]) :: :ok | {:error, :too_many_modes}
  defp validate_mode_limit(validated_modes) do
    max_modes_limit = Application.get_env(:elixircd, :channel)[:max_modes_per_command] || 20

    if length(validated_modes) > max_modes_limit do
      {:error, :too_many_modes}
    else
      :ok
    end
  end

  @spec send_channel_mode_listing(list(String.t()), User.t(), Channel.t()) :: :ok
  defp send_channel_mode_listing([], _user, _channel), do: :ok

  defp send_channel_mode_listing(["b"], user, channel) do
    created_timestamp =
      channel.created_at
      |> DateTime.to_unix()
      |> Integer.to_string()

    ChannelBans.get_by_channel_name_key(channel.name_key)
    |> Enum.each(fn channel_ban ->
      Message.build(%{
        prefix: :server,
        command: :rpl_banlist,
        params: [
          user.nick,
          channel.name,
          channel_ban.mask,
          channel_ban.setter,
          created_timestamp
        ]
      })
      |> Dispatcher.broadcast(user)
    end)

    Message.build(%{
      prefix: :server,
      command: :rpl_endofbanlist,
      params: [user.nick, channel.name],
      trailing: "End of channel ban list"
    })
    |> Dispatcher.broadcast(user)
  end

  @spec send_channel_mode_error(channel_mode_errors(), User.t(), String.t()) :: :ok
  defp send_channel_mode_error(:channel_not_found, user, channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_nosuchchannel,
      params: [user.nick, channel_name],
      trailing: "No such channel"
    })
    |> Dispatcher.broadcast(user)
  end

  defp send_channel_mode_error(:user_channel_not_found, user, channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_notonchannel,
      params: [user.nick, channel_name],
      trailing: "You're not on that channel"
    })
    |> Dispatcher.broadcast(user)
  end

  defp send_channel_mode_error(:user_is_not_operator, user, channel_name) do
    Message.build(%{
      prefix: :server,
      command: :err_chanoprivsneeded,
      params: [user.nick, channel_name],
      trailing: "You're not a channel operator"
    })
    |> Dispatcher.broadcast(user)
  end

  defp send_channel_mode_error(:too_many_modes, user, channel_name) do
    max_modes_limit = Application.get_env(:elixircd, :channel)[:max_modes_per_command] || 20

    Message.build(%{
      prefix: :server,
      command: :err_unknownmode,
      params: [user.nick, channel_name],
      trailing: "Too many channel modes in one command (maximum is #{max_modes_limit})"
    })
    |> Dispatcher.broadcast(user)
  end

  @spec handle_user_mode(User.t(), String.t(), String.t() | nil) :: :ok
  defp handle_user_mode(%{nick: user_nick} = user, receiver_nick, nil) when user_nick == receiver_nick do
    Message.build(%{prefix: :server, command: :rpl_umodeis, params: [user.nick, UserModes.display_modes(user.modes)]})
    |> Dispatcher.broadcast(user)
  end

  defp handle_user_mode(%{nick: user_nick} = user, receiver_nick, _mode_string) when user_nick != receiver_nick do
    Message.build(%{
      prefix: :server,
      command: :err_usersdontmatch,
      params: [user.nick],
      trailing: "Cannot change mode for other users"
    })
    |> Dispatcher.broadcast(user)
  end

  defp handle_user_mode(user, _receiver_nick, mode_string) do
    {validated_modes, invalid_modes} = UserModes.parse_mode_changes(mode_string)
    {updated_user, applied_changes} = UserModes.apply_mode_changes(user, validated_modes)

    if length(applied_changes) > 0 do
      Message.build(%{
        prefix: user_mask(user),
        command: "MODE",
        params: [updated_user.nick, UserModes.display_mode_changes(applied_changes)]
      })
      |> Dispatcher.broadcast(updated_user)
    end

    send_invalid_modes(invalid_modes, updated_user)
  end

  @spec send_invalid_modes(list(String.t()), User.t()) :: :ok
  defp send_invalid_modes([], _user), do: :ok

  defp send_invalid_modes(invalid_modes, user) do
    invalid_modes
    |> Enum.each(fn mode ->
      Message.build(%{
        prefix: :server,
        command: :err_unknownmode,
        params: [user.nick, mode],
        trailing: "is unknown mode char to me"
      })
      |> Dispatcher.broadcast(user)
    end)
  end
end
