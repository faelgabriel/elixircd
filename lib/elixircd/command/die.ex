defmodule ElixIRCd.Command.Die do
  @moduledoc """
  This module defines the DIE command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "DIE"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "DIE"}) do
    # Scenario: Operator issues DIE command
    # 1. Verify that the issuing user has operator privileges to use DIE.
    #    If not, respond with ERR_NOPRIVILEGES (481).
    # 2. Initiate the shutdown process to gracefully shutdown the server.
    # 3. Respond to the operator with RPL_SHUTDOWN (384) indicating that the shutdown
    #    process has started or has been completed.
    #    Example: ":server.name 384 your_nick :Shutting down"
    # Note: The DIE command is a critical operation and should be used with caution. It may
    # temporarily affect the server's performance or behavior as the server is shutdown.
    :ok
  end
end
