defmodule ElixIRCd.Command.Summon do
  @moduledoc """
  This module defines the SUMMON command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "SUMMON"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "SUMMON", params: []}) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply, "SUMMON"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "SUMMON", params: [target_nick | _rest]}) do
    # Scenarios to handle when target nickname is provided:
    # 1. Target user does not exist: ERR_NOSUCHNICK (401)
    # 2. Target user is not logged in: ERR_USERSDONTMATCH (502)
    # 3. Target user is already summoned: ERR_SUMMONDISABLED (445)
    # 4. Successful summon: Send RPL_SUMMONING (342) and handle possible RPL_AWAY (301)
    # Each condition leads to a specific IRC numeric response or action.
  end
end
