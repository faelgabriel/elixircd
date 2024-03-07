defmodule ElixIRCd.Command.Oper do
  @moduledoc """
  This module defines the OPER command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "OPER"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "OPER", params: params}) when length(params) <= 1 do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply, "OPER"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "OPER", params: [_username, _password | _rest]}) do
    # Scenario: User attempts to authenticate as an operator
    # 1. Validate the provided username and password against the server's list of authorized operators.
    # 2. If authentication fails, respond with ERR_PASSWDMISMATCH (464).
    # 3. If the username and password are correct, grant the user operator privileges.
    #    This involves setting appropriate user modes and possibly updating internal state to recognize the user as an oper.
    # 4. Respond with RPL_YOUREOPER (381) to acknowledge successful operator authentication.
    # Note: Implementing proper security measures for operator authentication is crucial,
    #       including secure storage and handling of passwords.
    :ok
  end
end
