defmodule ElixIRCd.Command.Lusers do
  @moduledoc """
  This module defines the LUSERS command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "LUSERS"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "LUSERS"}) do
    # Scenario: Client queries for network statistics
    # Any parameters provided with the LUSERS command are typically ignored.
    # Collect and respond with a series of statistics about the network:
    # - RPL_LUSERCLIENT (251): Display the total number of users, invisible users, and servers.
    #   Example: "There are <users> users and <invisible> invisible on <servers> servers"
    # - RPL_LUSEROP (252): Number of IRC Operators online.
    #   Example: "<count> IRC Operators online"
    # - RPL_LUSERUNKNOWN (253): Number of connections in an unknown state.
    #   Example: "<count> unknown connection(s)"
    # - RPL_LUSERCHANNELS (254): Number of channels formed.
    #   Example: "<count> channels formed"
    # - RPL_LUSERME (255): Server's client and server count.
    #   Example: "I have <clients> clients and <servers> servers"
    # - RPL_LOCALUSERS (265): Current local users count and the maximum observed.
    #   Example: "Current local users <current>, max <max>"
    # - RPL_GLOBALUSERS (266): Current global users count and the maximum observed.
    #   Example: "Current global users <current>, max <max>"
    # - Optionally, include RPL_LUSERSCONN (250) for the highest connection count with details.
    #   Example: "Highest connection count: <total> (<clients> clients) (<connections> connections received)"
    # The response provides a snapshot of the network's current state and capacity.
  end
end
