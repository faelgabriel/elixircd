defmodule ElixIRCd.Command.Pass do
  @moduledoc """
  This module defines the PASS command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: identity} = user, %{command: "PASS"}) when not is_nil(identity) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_alreadyregistered,
      params: [user_reply],
      trailing: "Unauthorized command (already registered)"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "PASS", params: []}) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply, "PASS"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "PASS", params: [_password | _rest]}) do
    # Scenario: User attempts to authenticate with a password
    # 1. Validate the provided password against the server's list of authorized users.
    # 2. If authentication fails, respond with ERR_PASSWDMISMATCH (464).
    # 3. If the password is correct, grant the user access to the server.
    #    This involves setting appropriate user modes and possibly updating internal state to recognize the user as authenticated.
    # 4. Respond with RPL_WELCOME (001) to acknowledge successful authentication.
    # Note: Implementing proper security measures for user authentication is crucial,
    #       including secure storage and handling of passwords.
    :ok
  end
end
