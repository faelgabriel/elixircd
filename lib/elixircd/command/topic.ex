defmodule ElixIRCd.Command.Topic do
  @moduledoc """
  This module defines the TOPIC command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "TOPIC"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "TOPIC", params: []}) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply, "TOPIC"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "TOPIC", params: [_channel_name | _rest], trailing: nil}) do
    # If a topic is set: 332 Nickname #channel :Current channel topic
    # If no topic is set: 331 Nickname #channel :No topic is set
    :ok
  end

  @impl true
  def handle(_user, %{command: "TOPIC", params: [_channel_name | _rest], trailing: _topic}) do
    # 482 Nickname #channel :You're not channel operator (If the channel is set to +t mode, and a non-operator user attempts to change the topic.)
    # 403 Nickname #channel :No such channel
    # 442 #channel :You're not on that channel

    # :Nickname!Username@Host TOPIC #channel :New topic here
    # Broadcast the new topic to all users in the channel
    :ok
  end
end
