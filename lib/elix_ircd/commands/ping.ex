defmodule ElixIRCd.Commands.Ping do
  @moduledoc """
  This module defines the PING command.
  """

  alias ElixIRCd.Handlers.MessageHandler

  @behaviour ElixIRCd.Behaviors.Command

  @impl true
  def handle(user, message_parts) when message_parts != [] do
    message = Enum.join(message_parts, " ")
    MessageHandler.send_message(user, :server, "PONG #{message}")
  end

  @impl true
  def handle(user, []) do
    MessageHandler.send_message(user, :server, "409 #{user.nick} :No origin specified")
  end
end
