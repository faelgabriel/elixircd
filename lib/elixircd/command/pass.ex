defmodule ElixIRCd.Command.Pass do
  @moduledoc """
  This module defines the PASS command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Repository.Users
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: true} = user, %{command: "PASS"}) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_alreadyregistered,
      params: [user_reply],
      trailing: "You may not reregister"
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
  def handle(user, %{command: "PASS", params: [password | _rest]}) do
    Users.update(user, %{password: password})
    :ok
  end
end
