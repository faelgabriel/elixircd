defmodule ElixIRCd.Command.Wallops do
  @moduledoc """
  This module defines the WALLOPS command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "WALLOPS"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "WALLOPS", trailing: nil}) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply, "WALLOPS"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "WALLOPS", trailing: message}) do
    # Scenario: User issues WALLOPS command with a message
    # The message is expected to be in the trailing part of the command,
    # allowing it to contain spaces without being split into multiple parameters.
    # Check if the user has the necessary privileges to send a WALLOPS message.
    # If so, broadcast the message to all users who have set the 'w' mode to receive such messages.
    # If not, respond with ERR_NOPRIVILEGES (481) or a similar error message.
  end
end
