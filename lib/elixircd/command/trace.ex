defmodule ElixIRCd.Command.Trace do
  @moduledoc """
  This module defines the TRACE command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "TRACE"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "TRACE", params: []}) do
    # Scenario: TRACE command issued without any parameters
    # The server should initiate a trace of the route to itself, providing details about each hop (server) in the path.
    # Respond with a series of TRACE replies, each indicating a part of the path within the network.
    # This might include RPL_TRACELINK, RPL_TRACECONNECTING, RPL_TRACEHANDSHAKE, RPL_TRACEUNKNOWN,
    # RPL_TRACEOPERATOR, RPL_TRACEUSER, RPL_TRACESERVER, and ends with RPL_TRACEEND.
    :ok
  end

  @impl true
  def handle(_user, %{command: "TRACE", params: [_target | _rest]}) do
    # Scenario: TRACE command issued with a target parameter
    # The server should initiate a trace towards the specified target, which could be a server or a user.
    # The response should detail each hop in the path to the target, similar to the no-parameter scenario.
    # The series of TRACE replies might vary depending on the target's location within the network
    #  and the server's ability to trace the route to the target.
    # The trace report concludes with RPL_TRACEEND to indicate the end of the trace.
    # Note: If the target is not found or the trace cannot be completed, the server should still respond with
    #  RPL_TRACEEND, possibly including an error message or indication that the target could not be reached.
    :ok
  end
end
