defmodule ElixIRCd.Commands.Ping do
  @moduledoc """
  This module defines the PING command.
  """

  alias ElixIRCd.Handlers.MessageHandler

  @behaviour ElixIRCd.Behaviors.Command

  @impl true
  def handle(user, %{command: "PING", params: [param]}) do
    MessageHandler.send_message(user, :server, "PONG #{param}")
  end

  @impl true
  def handle(user, %{command: "PING"}) do
    MessageHandler.send_message(user, :server, "409 #{user.nick} :No origin specified")
  end
end
