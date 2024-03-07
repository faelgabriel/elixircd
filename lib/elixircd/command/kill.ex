defmodule ElixIRCd.Command.Kill do
  @moduledoc """
  This module defines the KILL command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "KILL"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "KILL", params: []}) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply, "KILL"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "KILL", params: [_target_nick | _rest], trailing: _reason}) do
    # Scenarios to handle when a target nickname and reason are provided:
    # 1. Target user does not exist: ERR_NOSUCHNICK (401)
    # 2. Target user is the same as the user issuing the KILL command: ERR_CANTKILLSERVER (483)
    # 3. Successful KILL: Send RPL_KILL (349) and disconnect the target user
    # Each condition leads to a specific IRC numeric response or action.
    :ok
  end
end
