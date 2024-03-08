defmodule ElixIRCd.Command.Restart do
  @moduledoc """
  This module defines the RESTART command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "RESTART"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "RESTART"}) do
    # Scenario: Operator issues RESTART command
    # 1. Verify that the issuing user has operator privileges to use RESTART.
    #    If not, respond with ERR_NOPRIVILEGES (481).
    # 2. Initiate the restart process to reload the server's configuration file and restart the server.
    # 3. Respond to the operator with RPL_RESTARTING (384) indicating that the restart
    #    process has started or has been completed.
    #    Example: ":server.name 384 your_nick :Restarting"
    # Note: The RESTART command is a critical operation and should be used with caution. It may
    # temporarily affect the server's performance or behavior as the server is restarted.
    :ok
  end
end
