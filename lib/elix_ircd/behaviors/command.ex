defmodule ElixIRCd.Behaviors.Command do
  @moduledoc """
  This module defines the behaviour for the command handlers.
  """

  alias ElixIRCd.Schemas.User
  alias ElixIRCd.Structs.IrcMessage

  @doc """
  Handles the irc message command.
  """
  @callback handle(user :: User.t(), irc_message :: IrcMessage.t()) :: :ok
end
