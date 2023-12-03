defmodule ElixIRCd.Commands.Cap do
  @moduledoc """
  This module defines the CAP command.
  """

  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Message.MessageBuilder

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  def handle(user, %{command: "CAP", params: params}) do
    handle_cap_command(user, params)
  end

  defp handle_cap_command(user, ["LS", "302"]) do
    MessageBuilder.server_message("CAP", [user, "LS"])
    |> Messaging.send_message(user)
  end

  defp handle_cap_command(_user, _params) do
    # Ignores all other CAP commands since it is not supported yet.
    :ok
  end
end
