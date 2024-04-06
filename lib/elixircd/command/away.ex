defmodule ElixIRCd.Command.Away do
  @moduledoc """
  This module defines the AWAY command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: false} = user, %{command: "AWAY"}) do
    Message.build(%{prefix: :server, command: :err_notregistered, params: ["*"], trailing: "You have not registered"})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "AWAY", trailing: nil}) do
    Users.update(user, %{away_message: nil})

    Message.build(%{
      prefix: :server,
      command: :rpl_unaway,
      params: [user.nick],
      trailing: "You are no longer marked as being away"
    })
    |> Messaging.broadcast(user)

    :ok
  end

  @impl true
  def handle(user, %{command: "AWAY", trailing: reason}) do
    Users.update(user, %{away_message: reason})

    Message.build(%{
      prefix: :server,
      command: :rpl_nowaway,
      params: [user.nick],
      trailing: "You have been marked as being away"
    })
    |> Messaging.broadcast(user)

    :ok
  end
end
