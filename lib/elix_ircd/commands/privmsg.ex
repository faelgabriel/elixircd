defmodule ElixIRCd.Commands.Privmsg do
  @moduledoc """
  This module defines the PRIVMSG command.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Repo
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.MessageBuilder

  @behaviour ElixIRCd.Commands.Behavior
  @impl true
  def handle(%{identity: nil} = user, %{command: "PRIVMSG"}) do
    MessageBuilder.server_message(:err_notregistered, ["*"], "You have not registered")
    |> Messaging.send_message(user)
  end

  @impl true
  def handle(user, %{command: "PRIVMSG", params: [receiver], body: message}) do
    if String.starts_with?(receiver, "#"),
      do: handle_channel_message(user, receiver, message),
      else: handle_user_message(user, receiver, message)
  end

  @impl true
  def handle(user, %{command: "PRIVMSG"}) do
    MessageBuilder.server_message(:rpl_needmoreparams, [user.nick, "PRIVMSG"], "Not enough parameters")
    |> Messaging.send_message(user)
  end

  defp handle_channel_message(user, channel_name, message) do
    channel = Contexts.Channel.get_by_name(channel_name) |> Repo.preload(user_channels: :user)
    channel_users = channel.user_channels |> Enum.map(& &1.user)

    if Enum.member?(channel_users, user) do
      channel_users_without_user = Enum.reject(channel_users, &(&1 == user))

      MessageBuilder.user_message(user.identity, "PRIVMSG", [channel.name], message)
      |> Messaging.send_message(channel_users_without_user)
    else
      MessageBuilder.server_message(:rpl_cannotsendtochan, [user.nick, channel_name], "Cannot send to channel")
      |> Messaging.send_message(user)
    end
  end

  defp handle_user_message(user, receiver_nick, message) do
    case Contexts.User.get_by_nick(receiver_nick) do
      %Schemas.User{} = receiver_user ->
        MessageBuilder.user_message(receiver_user.identity, "PRIVMSG", [user.nick], message)
        |> Messaging.send_message(receiver_user)

      nil ->
        MessageBuilder.server_message(:rpl_nouser, [user.nick, receiver_nick], "No such nick")
        |> Messaging.send_message(user)
    end
  end
end
