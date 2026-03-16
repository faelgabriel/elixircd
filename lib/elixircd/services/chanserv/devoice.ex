defmodule ElixIRCd.Services.Chanserv.Devoice do
  @moduledoc """
  This module defines the ChanServ DEVOICE command.
  """

  @behaviour ElixIRCd.Service

  alias ElixIRCd.Services.Chanserv.Mode.Command
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["DEVOICE" | args]) do
    Command.handle(user, "DEVOICE", args, :voice, :remove)
  end
end
