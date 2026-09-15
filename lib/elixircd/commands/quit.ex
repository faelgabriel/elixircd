defmodule ElixIRCd.Commands.Quit do
  @moduledoc """
  This module defines the QUIT command.

  QUIT disconnects the user from the server with an optional quit message.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: {:quit, String.t()}
  def handle(user, %{command: "QUIT", trailing: quit_message}) do
    reason = quit_message || "Client Quit"

    %Message{command: "ERROR", params: [], trailing: "Closing connection: #{reason}"}
    |> Dispatcher.broadcast(:server, user)

    {:quit, reason}
  end
end
