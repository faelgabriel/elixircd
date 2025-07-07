defmodule ElixIRCd.Commands.Pass do
  @moduledoc """
  This module defines the PASS command.

  PASS sets the connection password during registration.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(%{registered: true} = user, %{command: "PASS"}) do
    Message.build(%{
      prefix: :server,
      command: :err_alreadyregistered,
      params: [user_reply(user)],
      trailing: "You may not reregister"
    })
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "PASS", params: []}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply(user), "PASS"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "PASS", params: [password | _rest]}) do
    Users.update(user, %{password: password})
    :ok
  end
end
