defmodule ElixIRCd.Command.Kick do
  @moduledoc """
  This module defines the KICK command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "KICK"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "KICK", params: params}) when length(params) <= 1 do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply, "KICK"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "KICK", params: [_channel_name, _target_nick | _rest], trailing: _reason}) do
    # 403 Nickname #channel :No such channel (If the channel doesn't exist)
    # 442 Nickname #channel :You're not on that channel (If the user trying to kick is not on the channel)
    # 482 Nickname #channel :You're not channel operator (If the user is not an operator of the channel)
    # Kick message to channel: :Nickname!Username@Host KICK #channel TargetUser :Reason
    # Note: The actual removal of the target user from the channel and broadcasting the kick message to all channel members would be implemented here.
    :ok
  end
end
