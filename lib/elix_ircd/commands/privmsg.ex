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
  def handle(user, %{command: "PRIVMSG", params: [receiver], body: message}) when user.identity != nil do
    case String.starts_with?(receiver, "#") do
      # Message is sent to a channel when receiver starts with #
      true ->
        channel = Contexts.Channel.get_by_name(receiver) |> Repo.preload(user_channels: :user)
        channel_users = channel.user_channels |> Enum.map(& &1.user)

        if channel_users |> Enum.member?(user) do
          channel_users_without_user =
            channel_users
            |> Enum.reject(fn x -> x == user end)

          MessageBuilder.user_message(user.identity, "PRIVMSG", [channel.name], message)
          |> Messaging.send_message(channel_users_without_user)
        else
          MessageBuilder.server_message(:rpl_cannotsendtochan, [user.nick, receiver], "Cannot send to channel")
          |> Messaging.send_message(user)
        end

      # Message is sent to a user
      false ->
        case Contexts.User.get_by_nick(receiver) do
          %Schemas.User{} = receiver_user ->
            MessageBuilder.user_message(receiver_user.identity, "PRIVMSG", [user.nick], message)
            |> Messaging.send_message(receiver_user)

          nil ->
            MessageBuilder.server_message(:rpl_nouser, [user.nick, receiver], "No such nick")
            |> Messaging.send_message(user)
        end
    end
  end

  @impl true
  def handle(user, %{command: "PRIVMSG"}) when user.identity != nil do
    MessageBuilder.server_message(:rpl_needmoreparams, [user.nick, "PRIVMSG"], "Not enough parameters")
    |> Messaging.send_message(user)
  end

  @impl true
  def handle(user, %{command: "PRIVMSG"}) do
    MessageBuilder.server_message(:err_notregistered, ["*"], "You have not registered")
    |> Messaging.send_message(user)
  end
end
