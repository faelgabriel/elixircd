defmodule ElixIRCd.Command.Ping do
  @moduledoc """
  This module defines the PING command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(user, %{command: "PING", trailing: trailing}) when not is_nil(trailing) do
    Message.build(%{prefix: :server, command: "PONG", params: [], trailing: trailing})
    |> Messaging.broadcast(user)
  end

  def handle(user, %{command: "PING", params: params}) when params != [] do
    Message.build(%{prefix: :server, command: "PONG", params: params})
    |> Messaging.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "PING"}) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply, "PING"],
      trailing: "Not enough parameters"
    })
    |> Messaging.broadcast(user)
  end
end
