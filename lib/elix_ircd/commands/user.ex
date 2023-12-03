defmodule ElixIRCd.Commands.User do
  @moduledoc """
  This module defines the USER command.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Handshake
  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Message.MessageBuilder

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  def handle(user, %{command: "USER", body: realname, params: [username, _, _]}) do
    {:ok, user} = Contexts.User.update(user, %{username: username, realname: realname})

    Handshake.handshake(user)
  end

  @impl true
  def handle(user, %{command: "USER"}) do
    user_reply = get_user_reply(user)

    MessageBuilder.server_message(:rpl_needmoreparams, [user_reply, "USER"], "Not enough parameters")
    |> Messaging.send_message(user)
  end

  @spec get_user_reply(Schemas.User.t()) :: String.t()
  # Reply with * if user has not yet registered, otherwise reply with user's nick
  defp get_user_reply(user) do
    case user.identity do
      nil -> "*"
      _ -> user.nick
    end
  end
end
