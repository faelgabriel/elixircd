defmodule ElixIRCd.Commands.Notice do
  @moduledoc """
  This module defines the NOTICE command.

  NOTICE sends a notice message to a user or channel without expecting a reply.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.MessageFilter,
    only: [check_registered_only_speak: 3, should_silence_message?: 2]

  import ElixIRCd.Utils.MessageText, only: [contains_formatting?: 1, ctcp_message?: 1, ctcp_action?: 1]

  import ElixIRCd.Utils.Protocol,
    only: [channel_name?: 1, channel_operator?: 1, channel_voice?: 1, service_name?: 1]

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
  def handle(%{registered: false}, %{command: "NOTICE"}), do: :ok

  @impl true
  def handle(user, %{command: "NOTICE", params: [target | _], trailing: trailing} = message)
      # Handle NOTICE when either:
      # 1. A trailing message is provided (standard IRC format)
      # 2. The message is included in params (alternative client format)
      when trailing != nil or length(message.params) > 1 do
    message_text = extract_message_text(message)

    cond do
      message_text == "" -> :ok
      channel_name?(target) -> handle_channel_message(user, target, message_text, message.tags)
      service_name?(target) -> :ok
      true -> handle_user_message(user, target, message_text, message.tags)
    end
  end

  @impl true
  def handle(_user, %{command: "NOTICE"}), do: :ok

  defp handle_channel_message(user, channel_name, message_text, message_tags) do
    user_channel =
      UserChannels.get_by_user_pid_and_channel_name(user.pid, channel_name)
      |> case do
        {:ok, user_channel} -> user_channel
        {:error, :user_channel_not_found} -> nil
      end

    with {:ok, channel} <- Channels.get_by_name(channel_name),
         :ok <- check_user_channel_modes(channel, user, user_channel),
         :ok <- check_registered_only_speak(channel, user, user_channel),
         :ok <- check_ctcp(channel, user, user_channel, message_text),
         :ok <- check_formatting(channel, user, message_text),
         :ok <- check_notice_blocked(channel, user_channel) do
      channel_users_without_user =
        UserChannels.get_by_channel_name(channel.name)
        |> Enum.reject(&(&1.user_pid == user.pid))

      user_pids = Enum.map(channel_users_without_user, & &1.user_pid)
      users = Users.get_by_pids(user_pids)

      %Message{command: "NOTICE", params: [channel.name], trailing: message_text, tags: message_tags}
      |> Dispatcher.broadcast_with_echo(user, users)
    else
      _error -> :ok
    end
  end

  defp handle_user_message(user, target_nick, message_text, message_tags) do
    case Users.get_by_nick(target_nick) do
      {:ok, receiver_user} -> handle_user_message(user, receiver_user, target_nick, message_text, message_tags)
      {:error, :user_not_found} -> :ok
    end
  end

  @spec handle_user_message(User.t(), User.t(), String.t(), String.t(), Message.tags()) :: :ok
  defp handle_user_message(user, receiver_user, target_nick, message_text, message_tags) do
    cond do
      should_silence_message?(receiver_user, user) ->
        :ok

      :R in receiver_user.modes and :r not in user.modes ->
        :ok

      :g in receiver_user.modes and
          is_nil(UserAccepts.get_by_user_pid_and_accepted_user_pid(receiver_user.pid, user.pid)) ->
        :ok

      true ->
        handle_normal_user_message(user, receiver_user, target_nick, message_text, message_tags)
    end
  end

  @spec handle_normal_user_message(User.t(), User.t(), String.t(), String.t(), Message.tags()) :: :ok
  defp handle_normal_user_message(user, receiver_user, target_nick, message_text, message_tags) do
    %Message{command: "NOTICE", params: [target_nick], trailing: message_text, tags: message_tags}
    |> Dispatcher.broadcast_with_echo(user, receiver_user)
  end

  # Extracts the message text from a NOTICE message
  # This function handles two different formats:
  # 1. Standard IRC format: trailing message
  # 2. Alternative client format: message in params
  @spec extract_message_text(Message.t()) :: String.t()
  defp extract_message_text(%{trailing: trailing}) when trailing != nil, do: trailing
  defp extract_message_text(%{params: [_ | rest_params]}) when rest_params != [], do: Enum.join(rest_params, " ")

  @spec check_user_channel_modes(Channel.t(), User.t(), UserChannel.t() | nil) ::
          :ok | {:error, :user_can_not_send} | {:error, :delay_message_blocked, integer()}
  # When user is not in channel
  defp check_user_channel_modes(channel, _user, nil) do
    if :m in channel.modes or :n in channel.modes do
      {:error, :user_can_not_send}
    else
      :ok
    end
  end

  # When user is in channel
  defp check_user_channel_modes(channel, _user, user_channel) do
    if :m in channel.modes do
      with :ok <- check_channel_moderated(channel, user_channel) do
        check_delay_message(channel, user_channel)
      end
    else
      check_delay_message(channel, user_channel)
    end
  end

  @spec check_channel_moderated(Channel.t(), UserChannel.t()) :: :ok | {:error, :user_can_not_send}
  defp check_channel_moderated(channel, user_channel) do
    if :m in channel.modes and not (channel_operator?(user_channel) or channel_voice?(user_channel)) do
      {:error, :user_can_not_send}
    else
      :ok
    end
  end

  @spec check_ctcp(Channel.t(), User.t(), UserChannel.t() | nil, String.t()) :: :ok | {:error, :ctcp_blocked}
  defp check_ctcp(channel, _user, user_channel, message_text) do
    if :C in channel.modes and ctcp_message?(message_text) and not ctcp_action?(message_text) and
         not user_can_send_ctcp?(user_channel) do
      {:error, :ctcp_blocked}
    else
      :ok
    end
  end

  @spec user_can_send_ctcp?(UserChannel.t() | nil) :: boolean()
  defp user_can_send_ctcp?(nil), do: false

  defp user_can_send_ctcp?(user_channel) do
    channel_operator?(user_channel) or channel_voice?(user_channel)
  end

  @spec check_formatting(Channel.t(), User.t(), String.t()) :: :ok | {:error, :formatting_blocked}
  defp check_formatting(channel, _user, message_text) do
    if :c in channel.modes and contains_formatting?(message_text) do
      {:error, :formatting_blocked}
    else
      :ok
    end
  end

  @spec check_notice_blocked(Channel.t(), UserChannel.t() | nil) :: :ok | {:error, :notice_blocked}
  defp check_notice_blocked(channel, user_channel) do
    if :T in channel.modes and not user_can_send_notice?(user_channel) do
      {:error, :notice_blocked}
    else
      :ok
    end
  end

  @spec user_can_send_notice?(UserChannel.t() | nil) :: boolean()
  defp user_can_send_notice?(nil), do: false

  defp user_can_send_notice?(user_channel) do
    channel_operator?(user_channel) or channel_voice?(user_channel)
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

  @spec extract_delay_mode_value([ElixIRCd.Commands.Mode.ChannelModes.mode()]) :: integer() | nil
  defp extract_delay_mode_value(modes) do
    Enum.find_value(modes, fn
      {:d, value} -> String.to_integer(value)
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
