defmodule ElixIRCd.Commands.User do
  @moduledoc """
  This module defines the USER command.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Handshake
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.Message
  alias ElixIRCd.Message.MessageBuilder

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(user, %{command: "USER", params: [username, _, _], body: realname}) do
    {:ok, user} = Contexts.User.update(user, %{username: username, realname: realname})

    Handshake.handshake(user)
  end

  @impl true
  def handle(user, %{command: "USER"}) do
    user_reply = MessageBuilder.get_user_reply(user)

    MessageBuilder.server_message(:rpl_needmoreparams, [user_reply, "USER"], "Not enough parameters")
    |> Messaging.send_message(user)
  end
end
