defmodule ElixIRCd.Commands.Cap do
  @moduledoc """
  This module defines the CAP command.
  """

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Protocol, only: [user_reply: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(user, %{command: "CAP", params: params}) do
    handle_cap_command(user, params)
  end

  @spec handle_cap_command(User.t(), [String.t()]) :: :ok
  defp handle_cap_command(user, ["LS", "302"]) do
    Message.build(%{prefix: :server, command: "CAP", params: [user_reply(user), "LS"]})
    |> Dispatcher.broadcast(user)
  end

  defp handle_cap_command(_user, _params) do
    # Ignores all other CAP commands since it is not supported yet.
    :ok
  end
end
