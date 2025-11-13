defmodule ElixIRCd.Commands.Notice do
  @moduledoc """
  This module defines the NOTICE command.

  NOTICE sends a notice message to a user or channel without expecting a reply.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.MessageFilter, only: [should_silence_message?: 2]
  import ElixIRCd.Utils.MessageText, only: [contains_formatting?: 1]
  import ElixIRCd.Utils.Protocol, only: [channel_name?: 1, channel_operator?: 1, channel_voice?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserAccepts
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "NOTICE"}) do
    %Message{command: :err_notregistered, params: ["*"], trailing: "You have not registered"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "NOTICE", params: []}) do
    %Message{command: :err_needmoreparams, params: [user.nick, "NOTICE"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "NOTICE", trailing: nil}) do
    %Message{command: :err_needmoreparams, params: [user.nick, "NOTICE"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "NOTICE", params: [target], trailing: message_text}) do
    if channel_name?(target),
      do: handle_channel_message(user, target, message_text),
      else: handle_user_message(user, target, message_text)
  end

  defp handle_channel_message(user, channel_name, message_text) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, user_channel} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name),
         :ok <- check_delay_message(channel, user_channel),
         :ok <- check_formatting(channel, message_text) do
      channel_users_without_user =
        UserChannels.get_by_channel_name(channel.name)
        |> Enum.reject(&(&1.user_pid == user.pid))

      user_pids = Enum.map(channel_users_without_user, & &1.user_pid)
      users = Users.get_by_pids(user_pids)

      %Message{command: "NOTICE", params: [channel.name], trailing: message_text}
      |> Dispatcher.broadcast(user, users)
    else
      {:error, :delay_message_blocked, delay} ->
        %Message{
          command: "937",
          params: [user.nick, channel_name],
          trailing: "You must wait #{delay} seconds after joining before speaking in this channel."
        }
        |> Dispatcher.broadcast(:server, user)

      {:error, :user_channel_not_found} ->
        %Message{command: :err_cannotsendtochan, params: [user.nick, channel_name], trailing: "Cannot send to channel"}
        |> Dispatcher.broadcast(:server, user)

      {:error, :channel_not_found} ->
        %Message{command: :err_nosuchchannel, params: [user.nick, channel_name], trailing: "No such channel"}
        |> Dispatcher.broadcast(:server, user)

      {:error, :formatting_blocked} ->
        %Message{
          command: "404",
          params: [user.nick, channel_name],
          trailing: "Cannot send to channel (+c - no colors allowed)"
        }
        |> Dispatcher.broadcast(:server, user)
    end
  end

  defp handle_user_message(user, target_nick, message_text) do
    case Users.get_by_nick(target_nick) do
      {:ok, receiver_user} -> handle_user_message(user, receiver_user, target_nick, message_text)
      {:error, :user_not_found} -> handle_user_not_found(user, target_nick)
    end
  end

  @spec handle_user_message(User.t(), User.t(), String.t(), String.t()) :: :ok
  defp handle_user_message(user, receiver_user, target_nick, message_text) do
    cond do
      should_silence_message?(receiver_user, user) ->
        :ok

      "R" in receiver_user.modes and "r" not in user.modes ->
        handle_restricted_user_message(user, receiver_user)

      "g" in receiver_user.modes and
          is_nil(UserAccepts.get_by_user_pid_and_accepted_user_pid(receiver_user.pid, user.pid)) ->
        handle_blocked_user_message(user, receiver_user)

      true ->
        handle_normal_user_message(user, receiver_user, target_nick, message_text)
    end
  end

  @spec handle_restricted_user_message(User.t(), User.t()) :: :ok
  defp handle_restricted_user_message(sender, recipient) do
    %Message{
      command: :err_cannotsendtouser,
      params: [sender.nick, recipient.nick],
      trailing: "You must be identified to message this user"
    }
    |> Dispatcher.broadcast(:server, sender)
  end

  @spec handle_blocked_user_message(User.t(), User.t()) :: :ok
  defp handle_blocked_user_message(sender, recipient) do
    %Message{
      command: :rpl_umodegmsg,
      params: [sender.nick, recipient.nick],
      trailing: "Your message has been blocked. #{recipient.nick} is only accepting messages from authorized users."
    }
    |> Dispatcher.broadcast(:server, sender)
  end

  @spec handle_normal_user_message(User.t(), User.t(), String.t(), String.t()) :: :ok
  defp handle_normal_user_message(user, receiver_user, target_nick, message_text) do
    %Message{command: "NOTICE", params: [target_nick], trailing: message_text}
    |> Dispatcher.broadcast(user, receiver_user)
  end

  @spec handle_user_not_found(User.t(), String.t()) :: :ok
  defp handle_user_not_found(user, target_nick) do
    %Message{command: :err_nosuchnick, params: [user.nick, target_nick], trailing: "No such nick"}
    |> Dispatcher.broadcast(:server, user)
  end

  @spec check_formatting(Channel.t(), String.t()) :: :ok | {:error, :formatting_blocked}
  defp check_formatting(channel, message_text) do
    if "c" in channel.modes and contains_formatting?(message_text) do
      {:error, :formatting_blocked}
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
