defmodule ElixIRCd.Command.Away do
  @moduledoc """
  This module defines the AWAY command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "AWAY"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "AWAY", trailing: nil}) do
    # Scenario: User requests to clear away status
    # Clear the user's away status
    # Respond with RPL_UNAWAY (305) indicating the user is no longer marked as being away
    :ok
  end

  @impl true
  def handle(_user, %{command: "AWAY", trailing: _reason}) do
    # Scenario: User requests to set away status with a reason
    # Set the user's away status with the provided reason
    # Respond with RPL_NOWAWAY (306) indicating the user has been marked as being away
    :ok
  end
end
