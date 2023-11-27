defmodule ElixIRCd.Commands.Privmsg do
  @moduledoc """
  This module defines the PRIVMSG command.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Repo
  alias ElixIRCd.Data.Schemas

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  def handle(user, %{command: "PRIVMSG", body: message, params: [receiver]}) when user.identity != nil do
    # Future:: move the logic to a separate function to check if receiver is a channel or a user
    case String.starts_with?(receiver, "#") do
      # Message is sent to a channel when receiver starts with #
      true ->
        channel = Contexts.Channel.get_by_name(receiver) |> Repo.preload(user_channels: :user)
        channel_users = channel.user_channels |> Enum.map(& &1.user)

        if channel_users |> Enum.member?(user) do
          Messaging.broadcast_except_for_user(
            channel_users,
            user,
            ":#{user.identity} PRIVMSG #{channel.name} :#{message}"
          )
        else
          Messaging.send_message(user, :server, "404 #{user.nick} #{receiver} :Cannot send to channel")
        end

      # Message is sent to a user
      false ->
        case Contexts.User.get_by_nick(receiver) do
          %Schemas.User{} = receiver_user ->
            Messaging.send_message(receiver_user, :user, "PRIVMSG #{user.nick} :#{message}")

          nil ->
            Messaging.send_message(user, :server, "401 #{user.nick} #{receiver} :No such nickname")
        end
    end
  end

  @impl true
  def handle(user, %{command: "PRIVMSG"}) when user.identity != nil do
    Messaging.message_not_enough_params(user, "PRIVMSG")
  end

  @impl true
  def handle(user, %{command: "PRIVMSG"}) do
    Messaging.message_not_registered(user)
  end
end
