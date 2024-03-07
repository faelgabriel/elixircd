defmodule ElixIRCd.Command.Ison do
  @moduledoc """
  This module defines the ISON command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "ISON"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "ISON", params: []}) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply, "ISON"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(_user, %{command: "ISON", params: _target_nicks}) do
    # Scenario: Checking the online status of specified nicknames
    # The command may include multiple nicknames separated by spaces in the params.
    # 1. Split the nicknames from the params.
    # 2. Check the online status for each nickname.
    # 3. Collect the nicknames that are currently online.
    # 4. Respond with RPL_ISON (303) listing all online nicknames from the queried list.
    # Note: If no nicknames are specified, the server might respond with RPL_ISON with an empty list.
    :ok
  end
end
