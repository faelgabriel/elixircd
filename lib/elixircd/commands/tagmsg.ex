defmodule ElixIRCd.Commands.Tagmsg do
  @moduledoc """
  This module defines the TAGMSG command.

  TAGMSG sends a tag-only message to a user or channel.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.MessageFilter, only: [check_registered_only_speak: 3, should_silence_message?: 2]

  import ElixIRCd.Utils.Protocol,
    only: [channel_name?: 1, channel_operator?: 1, channel_voice?: 1, service_name?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "TAGMSG"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "TAGMSG"} = message) do
    capabilities = user.capabilities || []

    if "MESSAGE-TAGS" in capabilities do
      do_handle(user, message)
    else
      %Message{command: :err_unknowncommand, params: [user.nick, "TAGMSG"], trailing: "Unknown command"}
      |> Dispatcher.broadcast(:server, user)
    end
  end

  defp do_handle(user, %{params: [target | _]} = message) do
    cond do
      channel_name?(target) -> handle_channel_tagmsg(user, target, message)
      service_name?(target) -> :ok
      true -> handle_user_tagmsg(user, target, message)
    end
  end

  defp do_handle(user, _message) do
    %Message{command: :err_needmoreparams, params: [user.nick, "TAGMSG"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec handle_channel_tagmsg(User.t(), String.t(), Message.t()) :: :ok
  defp handle_channel_tagmsg(user, channel_name, message) do
    user_channel =
      UserChannels.get_by_user_pid_and_channel_name(user.pid, channel_name)
      |> case do
        {:ok, user_channel} -> user_channel
        {:error, :user_channel_not_found} -> nil
      end

    with {:ok, channel} <- Channels.get_by_name(channel_name),
         :ok <- check_user_channel_modes(channel, user_channel),
         :ok <- check_registered_only_speak(channel, user, user_channel) do
      channel_users_without_user =
        UserChannels.get_by_channel_name(channel.name)
        |> Enum.reject(&(&1.user_pid == user.pid))

      user_pids = Enum.map(channel_users_without_user, & &1.user_pid)
      users = Users.get_by_pids(user_pids)

      # Preserve tags from original message
      %Message{command: "TAGMSG", params: [channel.name], trailing: nil, tags: message.tags}
      |> Dispatcher.broadcast(user, users)
    else
      {:error, :channel_not_found} ->
        %Message{command: :err_nosuchchannel, params: [user.nick, channel_name], trailing: "No such channel"}
        |> Dispatcher.broadcast(:server, user)

      {:error, :delay_message_blocked, delay} ->
        %Message{
          command: :err_delaymessageblocked,
          params: [user.nick, channel_name],
          trailing: "You must wait #{delay} seconds after joining before speaking in this channel."
        }
        |> Dispatcher.broadcast(:server, user)

      {:error, :user_can_not_send} ->
        %Message{command: :err_cannotsendtochan, params: [user.nick, channel_name], trailing: "Cannot send to channel"}
        |> Dispatcher.broadcast(:server, user)
    end
  end

  @spec handle_user_tagmsg(User.t(), String.t(), Message.t()) :: :ok
  defp handle_user_tagmsg(user, target_nick, message) do
    case Users.get_by_nick(target_nick) do
      {:ok, target_user} -> handle_user_tagmsg(user, target_user, target_nick, message)
      {:error, :user_not_found} -> handle_user_not_found(user, target_nick)
    end
  end

  @spec handle_user_tagmsg(User.t(), User.t(), String.t(), Message.t()) :: :ok
  defp handle_user_tagmsg(user, target_user, target_nick, message) do
    cond do
      should_silence_message?(target_user, user) ->
        :ok

      "R" in target_user.modes and "r" not in user.modes ->
        handle_restricted_user_message(user, target_user)

      true ->
        # Preserve tags from original message
        %Message{command: "TAGMSG", params: [target_nick], trailing: nil, tags: message.tags}
        |> Dispatcher.broadcast(user, target_user)

        :ok
    end
  end

  @spec handle_restricted_user_message(User.t(), User.t()) :: :ok
  defp handle_restricted_user_message(sender, recipient) do
    %Message{
      command: :err_needreggednick,
      params: [sender.nick, recipient.nick],
      trailing: "You must be identified to message this user"
    }
    |> Dispatcher.broadcast(:server, sender)
  end

  @spec handle_user_not_found(User.t(), String.t()) :: :ok
  defp handle_user_not_found(user, target_nick) do
    %Message{command: :err_nosuchnick, params: [user.nick, target_nick], trailing: "No such nick"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec check_user_channel_modes(Channel.t(), UserChannel.t() | nil) ::
          :ok | {:error, :user_can_not_send} | {:error, :delay_message_blocked, integer()}
  defp check_user_channel_modes(channel, nil) do
    if "m" in channel.modes or "n" in channel.modes do
      {:error, :user_can_not_send}
    else
      :ok
    end
  end

  defp check_user_channel_modes(channel, user_channel) do
    if "m" in channel.modes do
      with :ok <- check_channel_moderated(channel, user_channel) do
        check_delay_message(channel, user_channel)
      end
    else
      check_delay_message(channel, user_channel)
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
