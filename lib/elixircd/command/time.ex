defmodule ElixIRCd.Command.Time do
  @moduledoc """
  This module defines the TIME command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "TIME"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "TIME"}) do
    # Scenario: Client queries for server local time
    # Ignore any parameters provided with the TIME command as they are not typically used.
    # Respond with RPL_TIME (391), providing the server's local time in a human-readable format.
    # The format for RPL_TIME is typically: "<server> :<local time string>"
    # Example response might be: ":server.name 391 your_nick :Sun Nov 7 20:10:00 2021"
    # This provides the client with the current time from the server's perspective.
    :ok
  end
end
