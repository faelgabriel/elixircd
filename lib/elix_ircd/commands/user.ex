defmodule ElixIRCd.Commands.User do
  @moduledoc """
  This module defines the USER command.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Handlers.HandshakeHandler

  @behaviour ElixIRCd.Behaviors.Command

  @impl true
  def handle(user, %{command: "USER", body: realname, params: [username, _, _]}) do
    {:ok, user} = Contexts.User.update(user, %{username: username, realname: realname})

    HandshakeHandler.handshake(user)
  end
end
