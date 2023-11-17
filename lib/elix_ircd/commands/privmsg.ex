defmodule ElixIRCd.Commands.Privmsg do
  @moduledoc """
  This module defines the PRIVMSG command.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Handlers.MessageHandler
  alias ElixIRCd.Repo
  alias ElixIRCd.Schemas

  @behaviour ElixIRCd.Behaviors.Command
  @command "PRIVMSG"

  @impl true
  def handle(user, [receiver | message]) when user.identity != nil do
    # TODO: move the logic to a separate function to check if receiver is a channel or a user
    case String.starts_with?(receiver, "#") do
      # Message is sent to a channel when receiver starts with #
      true ->
        channel = Contexts.Channel.get_by_name(receiver) |> Repo.preload(user_channels: :user)
        channel_users = channel.user_channels |> Enum.map(& &1.user)

        if channel_users |> Enum.member?(user) do
          MessageHandler.broadcast_except_for_user(
            channel_users,
            user,
            ":#{user.identity} #{@command} #{channel.name} :#{message}"
          )
        else
          MessageHandler.send_message(user, :server, "404 #{user.nick} #{receiver} :Cannot send to channel")
        end

      # Message is sent to a user
      false ->
        case Contexts.User.get_by_nick(receiver) do
          %Schemas.User{} = receiver_user ->
            MessageHandler.send_message(receiver_user, :user, "#{@command} #{user.nick} :#{message}")

          nil ->
            MessageHandler.send_message(user, :server, "401 #{user.nick} #{receiver} :No such nickname")
        end
    end
  end

  @impl true
  def handle(user, []) when user.identity != nil do
    MessageHandler.message_not_enough_params(user, @command)
  end

  @impl true
  def handle(user, _) do
    MessageHandler.message_not_registered(user)
  end
end
