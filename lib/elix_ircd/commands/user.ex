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
  def handle(user, %{command: "USER"}) when user.identity != nil do
    MessageBuilder.server_message(:rpl_needmoreparams, [user.nick, "USER"], "Not enough parameters")
    |> Messaging.send_message(user)
  end

  @impl true
  def handle(user, %{command: "USER"}) do
    MessageBuilder.server_message(:rpl_needmoreparams, ["*", "USER"], "Not enough parameters")
    |> Messaging.send_message(user)
  end
end
