defmodule ElixIRCd.Commands.Behavior do
  @moduledoc """
  This module defines the behaviour for the command handlers.
  """

  alias ElixIRCd.Data.Schemas.User
  alias ElixIRCd.Message.Message

  @doc """
  Handles the irc message command.
  """
  @callback handle(user :: User.t(), irc_message :: Message.t()) :: :ok
end
