defmodule ElixIRCd.Command.Quit do
  @moduledoc """
  This module defines the QUIT command.
  """

  @behaviour ElixIRCd.Command

  alias ElixIRCd.Message
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), Message.t()) :: :ok
  def handle(user, %{command: "QUIT", trailing: quit_message}) do
    # Sends a quit message to the user socket process.
    send(user.pid, {:user_quit, user.socket, quit_message})

    :ok
  end
end
