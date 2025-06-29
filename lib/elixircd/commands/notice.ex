defmodule ElixIRCd.Commands.Notice do
  @moduledoc """
  This module defines the NOTICE command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_mask: 1, channel_name?: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Channels
  alias ElixIRCd.Repositories.UserAccepts
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "NOTICE"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "NOTICE", params: []}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "NOTICE"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "NOTICE", trailing: nil}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user.nick, "NOTICE"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "NOTICE", params: [target], trailing: message}) do
    if channel_name?(target),
      do: handle_channel_message(user, target, message),
      else: handle_user_message(user, target, message)
  end

  defp handle_channel_message(user, channel_name, message) do
    with {:ok, channel} <- Channels.get_by_name(channel_name),
         {:ok, _user_channel} <- UserChannels.get_by_user_pid_and_channel_name(user.pid, channel.name) do
      channel_users_without_user =
        UserChannels.get_by_channel_name(channel.name)
        |> Enum.reject(&(&1.user_pid == user.pid))

      Message.build(%{
        prefix: user_mask(user),
        command: "NOTICE",
        params: [channel.name],
        trailing: message
      })
      |> Dispatcher.broadcast(channel_users_without_user)
    else
      {:error, :user_channel_not_found} ->
        Message.build(%{
          prefix: :server,
          command: :err_cannotsendtochan,
          params: [user.nick, channel_name],
          trailing: "Cannot send to channel"
        })
        |> Dispatcher.broadcast(user)

      {:error, :channel_not_found} ->
        Message.build(%{
          prefix: :server,
          command: :err_nosuchchannel,
          params: [user.nick, channel_name],
          trailing: "No such channel"
        })
        |> Dispatcher.broadcast(user)
    end
  end

  defp handle_user_message(user, target_nick, message) do
    case Users.get_by_nick(target_nick) do
      {:ok, receiver_user} -> handle_user_message(user, receiver_user, target_nick, message)
      {:error, :user_not_found} -> handle_user_not_found(user, target_nick)
    end
  end

  @spec handle_user_message(User.t(), User.t(), String.t(), String.t()) :: :ok
  defp handle_user_message(user, receiver_user, target_nick, message) do
    cond do
      "R" in receiver_user.modes and "r" not in user.modes ->
        handle_restricted_user_message(user, receiver_user)

      "g" in receiver_user.modes and
          is_nil(UserAccepts.get_by_user_pid_and_accepted_user_pid(receiver_user.pid, user.pid)) ->
        handle_blocked_user_message(user, receiver_user)

      true ->
        handle_normal_user_message(user, receiver_user, target_nick, message)
    end
  end

  @spec handle_restricted_user_message(User.t(), User.t()) :: :ok
  defp handle_restricted_user_message(sender, recipient) do
    Message.build(%{
      prefix: :server,
      command: :err_cannotsendtouser,
      params: [sender.nick, recipient.nick],
      trailing: "You must be identified to message this user"
    })
    |> Dispatcher.broadcast(sender)
  end

  @spec handle_blocked_user_message(User.t(), User.t()) :: :ok
  defp handle_blocked_user_message(sender, recipient) do
    Message.build(%{
      prefix: :server,
      command: :rpl_umodegmsg,
      params: [sender.nick, recipient.nick],
      trailing: "Your message has been blocked. #{recipient.nick} is only accepting messages from authorized users."
    })
    |> Dispatcher.broadcast(sender)
  end

  @spec handle_normal_user_message(User.t(), User.t(), String.t(), String.t()) :: :ok
  defp handle_normal_user_message(user, receiver_user, target_nick, message) do
    Message.build(%{
      prefix: user_mask(user),
      command: "NOTICE",
      params: [target_nick],
      trailing: message
    })
    |> Dispatcher.broadcast(receiver_user)
  end

  @spec handle_user_not_found(User.t(), String.t()) :: :ok
  defp handle_user_not_found(user, target_nick) do
    Message.build(%{
      prefix: :server,
      command: :err_nosuchnick,
      params: [user.nick, target_nick],
      trailing: "No such nick"
    })
    |> Dispatcher.broadcast(user)
  end
end
