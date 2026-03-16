defmodule ElixIRCd.Services.Chanserv.Op do
  @moduledoc """
  This module defines the ChanServ OP command.
  """

  @behaviour ElixIRCd.Service

  alias ElixIRCd.Services.Chanserv.Mode.Command
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["OP" | args]) do
    Command.handle(user, "OP", args, :op, :add)
  end
end
