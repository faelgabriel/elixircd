defmodule ElixIRCd.Commands.Cap do
  @moduledoc """
  This module defines the CAP command.
  """

  alias ElixIRCd.Core.Messaging
  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message.Message
  alias ElixIRCd.Message.MessageBuilder

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(user, %{command: "CAP", params: params}) do
    handle_cap_command(user, params)
  end

  defp handle_cap_command(user, ["LS", "302"]) do
    user_reply = MessageBuilder.get_user_reply(user)

    MessageBuilder.server_message("CAP", [user_reply, "LS"])
    |> Messaging.send_message(user)
  end

  defp handle_cap_command(_user, _params) do
    # Ignores all other CAP commands since it is not supported yet.
    :ok
  end
end
