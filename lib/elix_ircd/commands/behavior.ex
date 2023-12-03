defmodule ElixIRCd.Commands.Behavior do
  @moduledoc """
  This module defines the behaviour for the command handlers.
  """

  alias ElixIRCd.Data.Schemas.User
  alias ElixIRCd.Message.Message

  @doc """
  Handles the irc message command.

  Modules that implement this behaviour should define their own logic for handling IRC commands.
  """
  @callback handle(user :: User.t(), message :: Message.t()) :: :ok
end
