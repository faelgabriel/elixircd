defmodule ElixIRCd.Commands.Ping do
  @moduledoc """
  This module defines the PING command.
  """

  alias ElixIRCd.Core.Messaging

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  def handle(user, %{command: "PING", body: body}) do
    Messaging.send_message(user, :server, "PONG #{body}")
  end

  @impl true
  def handle(user, %{command: "PING"}) do
    Messaging.send_message(user, :server, "409 #{user.nick} :No origin specified")
  end
end
