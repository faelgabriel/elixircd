defmodule ElixIRCd.Commands.Quit do
  @moduledoc """
  This module defines the QUIT command.

  QUIT disconnects the user from the server with an optional quit message.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: {:quit, String.t()}
  def handle(_user, %{command: "QUIT", trailing: quit_message}) do
    {:quit, quit_message}
  end
end
