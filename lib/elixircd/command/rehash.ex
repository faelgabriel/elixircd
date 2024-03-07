defmodule ElixIRCd.Command.Rehash do
  @moduledoc """
  This module defines the REHASH command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "REHASH"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "REHASH"}) do
    # Scenario: Operator issues REHASH command
    # 1. Verify that the issuing user has operator privileges to use REHASH.
    #    If not, respond with ERR_NOPRIVILEGES (481).
    # 2. Initiate the rehash process to reload the server's configuration file.
    #    This involves reading the configuration file again and applying any changes.
    # 3. Respond to the operator with RPL_REHASHING (382) indicating that the rehash
    #    process has started or has been completed, including the name of the configuration file.
    #    Example: ":server.name 382 your_nick config.conf :Rehashing"
    # Note: The REHASH command is a critical operation and should be used with caution. It may
    # temporarily affect the server's performance or behavior as the new configuration is applied.
    :ok
  end
end
