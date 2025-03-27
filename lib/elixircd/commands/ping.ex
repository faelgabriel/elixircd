defmodule ElixIRCd.Commands.Ping do
  @moduledoc """
  This module defines the PING command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(user, %{command: "PING", trailing: trailing}) when not is_nil(trailing) do
    Message.build(%{prefix: :server, command: "PONG", params: [], trailing: trailing})
    |> Dispatcher.broadcast(user)
  end

  def handle(user, %{command: "PING", params: params}) when params != [] do
    Message.build(%{prefix: :server, command: "PONG", params: params})
    |> Dispatcher.broadcast(user)
  end

  @impl true
  def handle(user, %{command: "PING"}) do
    Message.build(%{
      prefix: :server,
      command: :err_needmoreparams,
      params: [user_reply(user), "PING"],
      trailing: "Not enough parameters"
    })
    |> Dispatcher.broadcast(user)
  end
end
