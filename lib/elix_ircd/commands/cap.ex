defmodule ElixIRCd.Commands.Cap do
  @moduledoc """
  This module defines the CAP command.
  """

  alias ElixIRCd.Handlers.MessageHandler

  @behaviour ElixIRCd.Behaviors.Command

  @impl true
  def handle(user, ["LS", "302"]) do
    MessageHandler.send_message(user, :server, "CAP * LS :")
    :ok
  end

  @impl true
  def handle(_user, _) do
    # Ignores all other CAP commands since it is not supported yet.
    :ok
  end
end
