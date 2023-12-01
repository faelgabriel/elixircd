defmodule ElixIRCd.Commands.Cap do
  @moduledoc """
  This module defines the CAP command.
  """

  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Message.MessageBuilder

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  def handle(user, %{command: "CAP", params: ["LS", "302"]}) do
    MessageBuilder.server_message("CAP", ["*", "LS"])
    |> Messaging.send_message(user)
  end

  @impl true
  def handle(_user, %{command: "CAP"}) do
    # Ignores all other CAP commands since it is not supported yet.
    :ok
  end
end
