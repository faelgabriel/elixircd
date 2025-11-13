defmodule ElixIRCd.Commands.Ping do
  @moduledoc """
  This module defines the PING command.

  PING tests the connection between client and server, expecting a PONG response.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(user, %{command: "PING", trailing: trailing}) when not is_nil(trailing) do
    %Message{command: "PONG", params: [], trailing: trailing}
    |> Dispatcher.broadcast(:server, user)
  end

  def handle(user, %{command: "PING", params: params}) when params != [] do
    %Message{command: "PONG", params: params}
    |> Dispatcher.broadcast(:server, user)
  end

  @impl true
  def handle(user, %{command: "PING"}) do
    %Message{command: :err_needmoreparams, params: [user_reply(user), "PING"], trailing: "Not enough parameters"}
    |> Dispatcher.broadcast(:server, user)
  end
end
