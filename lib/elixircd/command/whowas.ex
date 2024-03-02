defmodule ElixIRCd.Command.Whowas do
  @moduledoc """
  This module defines the WHOWAS command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{identity: nil} = user, %{command: "WHOWAS"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "WHOWAS", params: []}) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply, "WHOWAS"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "WHOWAS", params: [_target_nick]}) do
    # Scenario: WHOWAS request with a specific user pattern
    # Respond with a series of RPL_WHOWASUSER (314), RPL_WHOISSERVER (312), and RPL_ENDOFWHOWAS (369) messages
    :ok
  end

  @impl true
  def handle(_user, %{command: "WHOWAS", params: [_target_nick, _max_replies | _rest]}) do
    # Scenario: WHOWAS request with a specific user pattern
    # Respond with a series of RPL_WHOWASUSER (314), RPL_WHOISSERVER (312), and RPL_ENDOFWHOWAS (369) messages
    :ok
  end
end
