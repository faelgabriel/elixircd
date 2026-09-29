defmodule ElixIRCd.Commands.Notice do
  @moduledoc """
  This module defines the NOTICE command.

  NOTICE sends a notice message to a user or channel without expecting a reply.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.MessageFilter,
    only: [
      filter_op_moderated_users: 3,
      private_ctcp_blocked?: 2,
      should_silence_message?: 2
    ]

  import ElixIRCd.Utils.Protocol,
    only: [channel_name?: 1, service_name?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserAccepts
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.ServerLink.ChannelMessage
  alias ElixIRCd.ServerLink.ChannelMessage.LocalSelection
  alias ElixIRCd.ServerLink.DirectMessage
  alias ElixIRCd.ServerLink.Directory
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.Statusmsg
  alias ElixIRCd.Utils.Targets

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false}, %{command: "NOTICE"}), do: :ok

  @impl true
  def handle(user, %{command: "NOTICE", params: [targets | _], trailing: trailing} = message)
      # Handle NOTICE when either:
      # 1. A trailing message is provided (standard IRC format)
      # 2. The message is included in params (alternative client format)
      when trailing != nil or length(message.params) > 1 do
    message_text = extract_message_text(message)

    if message_text == "" and not ElixIRCd.Multiline.collecting?() do
      :ok
    else
      Targets.split("NOTICE", targets)
      |> Enum.each(&handle_target(user, &1, message_text, message.tags))
    end
  end

  @impl true
  def handle(_user, %{command: "NOTICE"}), do: :ok

  @spec handle_target(User.t(), String.t(), String.t(), Message.tags()) :: :ok
  defp handle_target(user, target, message_text, message_tags) do
    case Statusmsg.parse(target) do
      {:ok, channel_name, status_prefix} ->
        handle_channel_message(user, channel_name, message_text, message_tags, target, status_prefix)

      :error ->
        cond do
          channel_name?(target) -> handle_channel_message(user, target, message_text, message_tags)
          service_name?(target) -> :ok
          true -> handle_user_message(user, target, message_text, message_tags)
        end
    end
  end

  defp handle_channel_message(user, channel_name, message_text, message_tags) do
    handle_channel_message(user, channel_name, message_text, message_tags, channel_name, nil)
  end

  defp handle_channel_message(user, channel_name, message_text, message_tags, wire_target, status_prefix) do
    user_channel =
      UserChannels.get_by_user_pid_and_channel_name(user.pid, channel_name)
      |> case do
        {:ok, user_channel} -> user_channel
        {:error, :user_channel_not_found} -> nil
      end

    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, %LocalSelection{channel: selected, view: view}} <- ChannelMessage.select_local(channel),
         :ok <- ChannelMessage.check_local_permissions(selected, view, user, user_channel, "NOTICE", message_text) do
      if Application.fetch_env!(:elixircd, :server_links)[:enabled] and not ElixIRCd.Multiline.collecting?() do
        ChannelMessage.queue_local(user, selected, wire_target, "NOTICE", message_text, message_tags)
      else
        channel_users_without_user =
          UserChannels.get_by_channel_name(selected.name)
          |> Enum.reject(&(&1.user_pid == user.pid))
          |> maybe_filter_status(status_prefix)
          |> filter_op_moderated_users(user_channel, selected.modes)

        user_pids = Enum.map(channel_users_without_user, & &1.user_pid)
        users = Users.get_by_pids(user_pids)

        %Message{command: "NOTICE", params: [wire_target], trailing: message_text, tags: message_tags}
        |> Dispatcher.broadcast_with_echo(user, users)

        ChannelMessage.send_from_local(user, selected.name, wire_target, "NOTICE", message_text, message_tags)
      end
    else
      _error -> :ok
    end
  end

  @spec maybe_filter_status([UserChannel.t()], String.t() | nil) :: [UserChannel.t()]
  defp maybe_filter_status(user_channels, nil), do: user_channels
  defp maybe_filter_status(user_channels, prefix), do: Enum.filter(user_channels, &Statusmsg.eligible?(&1, prefix))

  defp handle_user_message(user, target_nick, message_text, message_tags) do
    case Users.get_by_nick(target_nick) do
      {:ok, receiver_user} -> handle_user_message(user, receiver_user, target_nick, message_text, message_tags)
      {:error, :user_not_found} -> send_remote_notice(user, target_nick, message_text, message_tags)
    end
  end

  defp send_remote_notice(user, target_nick, message_text, message_tags) do
    case Directory.get_by_nick(target_nick) do
      {:ok, remote} ->
        DirectMessage.send_from_local(user, remote, "NOTICE", message_text, message_tags)

      :error ->
        :ok
    end
  end

  @spec handle_user_message(User.t(), User.t(), String.t(), String.t(), Message.tags()) :: :ok
  defp handle_user_message(user, receiver_user, target_nick, message_text, message_tags) do
    cond do
      should_silence_message?(receiver_user, user) ->
        :ok

      private_ctcp_blocked?(receiver_user, message_text) ->
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
end
