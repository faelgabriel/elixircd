defmodule ElixIRCd.Commands.Ping do
  @moduledoc """
  This module defines the PING command.
  """

  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Message.MessageBuilder

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  def handle(user, %{command: "PING", body: body}) do
    MessageBuilder.server_message("PONG", [], body)
    |> Messaging.send_message(user)
  end

  @impl true
  def handle(user, %{command: "PING"}) do
    MessageBuilder.server_message(:rpl_needmoreparams, [user, "PING"], "Not enough parameters")
    |> Messaging.send_message(user)
  end
end
