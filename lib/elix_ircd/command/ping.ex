defmodule ElixIRCd.Command.Ping do
  @moduledoc """
  This module defines the PING command.
  """

  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server

  @behaviour ElixIRCd.Command

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(user, %{command: "PING", body: body}) do
    Message.new(%{source: :server, command: "PONG", params: [], body: body})
    |> Server.send_message(user)
  end

  @impl true
  def handle(user, %{command: "PING"}) do
    user_reply = Helper.get_user_reply(user)

    Message.new(%{
      source: :server,
      command: :err_needmoreparams,
      params: [user_reply, "PING"],
      body: "Not enough parameters"
    })
    |> Server.send_message(user)
  end
end
