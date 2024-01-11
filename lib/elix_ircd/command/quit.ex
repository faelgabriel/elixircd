defmodule ElixIRCd.Command.Quit do
  @moduledoc """
  This module defines the QUIT command.
  """

  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message

  @behaviour ElixIRCd.Command

  @impl true
  @spec handle(Schemas.User.t(), Message.t()) :: :ok
  def handle(user, %{command: "QUIT", body: quit_message}) do
    # Sends a quit message to the user socket process.
    send(user.pid, {:user_quit, user.socket, quit_message})

    :ok
  end
end
