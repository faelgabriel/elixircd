defmodule ElixIRCd.Services.Chanserv.Voice do
  @moduledoc """
  This module defines the ChanServ VOICE command.
  """

  @behaviour ElixIRCd.Service

  alias ElixIRCd.Services.Chanserv.Mode.Command
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["VOICE" | args]) do
    Command.handle(user, "VOICE", args, :voice, :add)
  end
end
