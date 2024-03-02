defmodule ElixIRCd.Command.Cap do
  @moduledoc """
  This module defines the CAP command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Helper
  alias ElixIRCd.Message
  alias ElixIRCd.Server.Messaging
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(user, %{command: "CAP", params: params}) do
    handle_cap_command(user, params)
  end

  @spec handle_cap_command(User.t(), [String.t()]) :: :ok
  defp handle_cap_command(user, ["LS", "302"]) do
    user_reply = Helper.get_user_reply(user)

    Message.build(%{prefix: :server, command: "CAP", params: [user_reply, "LS"]})
    |> Messaging.broadcast(user)
  end

  defp handle_cap_command(_user, _params) do
    # Ignores all other CAP commands since it is not supported yet.
    :ok
  end
end
