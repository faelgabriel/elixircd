defmodule ElixIRCd.Commands.Quit do
  @moduledoc """
  This module defines the QUIT command.
  """

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  def handle(user, %{command: "QUIT", body: quit_message}) do
    # Sends a quit message to the user socket process.
    send(user.pid, {:quit, user.socket, quit_message})

    :ok
  end
end
