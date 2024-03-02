defmodule ElixIRCd.Command.Motd do
  @moduledoc """
  This module defines the MOTD command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "MOTD"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "MOTD"}) do
    # Scenario: Client requests the Message of the Day
    # 1. Check if the MOTD file exists and is accessible.
    #    If not, respond with ERR_NOMOTD (422) indicating the MOTD is not available.
    # 2. If the MOTD is available, respond with a series of RPL_MOTD (372) messages, each containing a line of the MOTD.
    # 3. Begin the MOTD sequence with RPL_MOTDSTART (375) and end with RPL_ENDOFMOTD (376) to frame the message.
    # Example:
    #    ":server.name 375 your_nick :- server.name Message of the Day - "
    #    ":server.name 372 your_nick :- Welcome to our IRC network!"
    #    ":server.name 376 your_nick :End of /MOTD command"
    # Note: The MOTD is often used to communicate important information and policies to users, so it should be kept up-to-date.
  end
end
