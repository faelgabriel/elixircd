defmodule ElixIRCd.Command.Admin do
  @moduledoc """
  This module defines the ADMIN command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "ADMIN"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "ADMIN", params: [_server | _rest]}) do
    # Scenario: Client queries for server administrative information
    # Ignore any parameters provided with the ADMIN command as they are not typically used.
    # Respond with a series of replies to provide administrative contact information:
    # - RPL_ADMINME (256): The name of the server.
    #   Example: ":server.name 256 your_nick :Administrative info about server.name"
    # - RPL_ADMINLOC1 (257): The first line of administrative info (e.g., server location).
    #   Example: ":server.name 257 your_nick :Server Location Here"
    # - RPL_ADMINLOC2 (258): The second line of administrative info (e.g., organization name).
    #   Example: ":server.name 258 your_nick :Organization Name Here"
    # - RPL_ADMINEMAIL (259): The administrator's contact email.
    #   Example: ":server.name 259 your_nick :admin@example.com"
    # This provides the client with the necessary contact information for server administration.
    :ok
  end

  @impl true
  def handle(_user, %{command: "ADMIN"}) do
    # Scenario: Client queries for server administrative information
    # Ignore any parameters provided with the ADMIN command as they are not typically used.
    # Respond with a series of replies to provide administrative contact information:
    # - RPL_ADMINME (256): The name of the server.
    #   Example: ":server.name 256 your_nick :Administrative info about server.name"
    # - RPL_ADMINLOC1 (257): The first line of administrative info (e.g., server location).
    #   Example: ":server.name 257 your_nick :Server Location Here"
    # - RPL_ADMINLOC2 (258): The second line of administrative info (e.g., organization name).
    #   Example: ":server.name 258 your_nick :Organization Name Here"
    # - RPL_ADMINEMAIL (259): The administrator's contact email.
    #   Example: ":server.name 259 your_nick :admin@example.com"
    # This provides the client with the necessary contact information for server administration.
    :ok
  end
end
