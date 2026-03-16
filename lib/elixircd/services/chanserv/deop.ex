defmodule ElixIRCd.Services.Chanserv.Deop do
  @moduledoc """
  This module defines the ChanServ DEOP command.
  """

  @behaviour ElixIRCd.Service

  alias ElixIRCd.Services.Chanserv.Mode.Command
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["DEOP" | args]) do
    Command.handle(user, "DEOP", args, :op, :remove)
  end
end
