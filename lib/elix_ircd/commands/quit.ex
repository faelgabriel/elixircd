defmodule ElixIRCd.Commands.Quit do
  @moduledoc """
  This module defines the QUIT command.
  """

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  def handle(user, %{command: "QUIT", body: quit_message}) do
    # Finds the user socket process and sends a quit message.
    [{socket_pid, _}] = Registry.lookup(ElixIRCd.Protocols.Registry, user.socket)
    send(socket_pid, {:quit, user.socket, quit_message})

    :ok
  end
end
