defmodule ElixIRCd.Command.Behavior do
  @moduledoc """
  This module defines the behaviour for the command handlers.
  """

  alias ElixIRCd.Data.Schemas
  alias ElixIRCd.Message

  @doc """
  Handles the irc message command.

  Modules that implement this behaviour should define their own logic for handling IRC commands.
  """
  @callback handle(user :: Schemas.User.t(), message :: Message.t()) :: :ok
end
