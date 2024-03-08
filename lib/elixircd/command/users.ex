defmodule ElixIRCd.Command.Users do
  @moduledoc """
  This module defines the USERS command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "USERS"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "USERS"}) do
    # Scenario: User requests a list of users logged into the server
    # 1. Respond with RPL_USERSSTART (392) to indicate the start of the user list
    # 2. For each user, send RPL_USERS (393) with details about the user
    # 3. Respond with RPL_ENDOFUSERS (394) to indicate the end of the user list
    :ok
  end
end
