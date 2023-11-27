defmodule ElixIRCd.Commands.User do
  @moduledoc """
  This module defines the USER command.
  """

  alias ElixIRCd.Contexts
  alias ElixIRCd.Core.Handshake

  @behaviour ElixIRCd.Commands.Behavior

  @impl true
  def handle(user, %{command: "USER", body: realname, params: [username, _, _]}) do
    {:ok, user} = Contexts.User.update(user, %{username: username, realname: realname})

    Handshake.handshake(user)
  end
end
