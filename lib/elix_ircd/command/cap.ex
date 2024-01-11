defmodule ElixIRCd.Command.Cap do
  @moduledoc """
  This module defines the CAP command.
  """

  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server

  @behaviour ElixIRCd.Command

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(user, %{command: "CAP", params: params}) do
    handle_cap_command(user, params)
  end

  defp handle_cap_command(user, ["LS", "302"]) do
    user_reply = Helper.get_user_reply(user)

    Message.new(%{source: :server, command: "CAP", params: [user_reply, "LS"]})
    |> Server.send_message(user)
  end

  defp handle_cap_command(_user, _params) do
    # Ignores all other CAP commands since it is not supported yet.
    :ok
  end
end
