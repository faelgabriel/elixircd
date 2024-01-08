defmodule ElixIRCd.Command.User do
  @moduledoc """
  This module defines the USER command.
  """

  alias ElixIRCd.Data.Contexts
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server
  alias ElixIRCd.Server.Handshake

  @behaviour ElixIRCd.Command.Behavior

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(user, %{command: "USER", params: [username, _, _], body: realname}) do
    {:ok, user} = Contexts.User.update(user, %{username: username, realname: realname})

    Handshake.handle(user)
  end

  @impl true
  def handle(user, %{command: "USER"}) do
    user_reply = Helper.get_user_reply(user)

    Message.new(%{
      source: :server,
      command: :err_needmoreparams,
      params: [user_reply, "USER"],
      body: "Not enough parameters"
    })
    |> Server.send_message(user)
  end
end
