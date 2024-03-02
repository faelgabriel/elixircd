defmodule ElixIRCd.Command.Info do
  @moduledoc """
  This module defines the INFO command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "INFO"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "INFO", params: [_server | _rest]}) do
    # Scenario: Client queries for server and network information
    # Ignore any parameters provided with the INFO command as they are not typically used.
    # Respond with a series of replies to provide detailed information about the server:
    # - RPL_INFO (371): Send multiple RPL_INFO messages, each containing a line of text
    #   about the server's software, authors, copyright, and other details.
    #   Example: ":server.name 371 your_nick :IRCd version x.y, developed by..."
    # - RPL_ENDOFINFO (374): Indicate the end of the INFO response.
    #   Example: ":server.name 374 your_nick :End of /INFO list"
    # This sequence provides the client with detailed insights into the server and its network's background and policies.
    :ok
  end

  @impl true
  def handle(_user, %{command: "INFO"}) do
    # Scenario: Client queries for server and network information
    # Ignore any parameters provided with the INFO command as they are not typically used.
    # Respond with a series of replies to provide detailed information about the server:
    # - RPL_INFO (371): Send multiple RPL_INFO messages, each containing a line of text
    #   about the server's software, authors, copyright, and other details.
    #   Example: ":server.name 371 your_nick :IRCd version x.y, developed by..."
    # - RPL_ENDOFINFO (374): Indicate the end of the INFO response.
    #   Example: ":server.name 374 your_nick :End of /INFO list"
    # This sequence provides the client with detailed insights into the server and its network's background and policies.
    :ok
  end
end
