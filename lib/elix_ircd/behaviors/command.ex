defmodule ElixIRCd.Behaviors.Command do
  @moduledoc """
  This module defines the behaviour for a command.
  """

  alias ElixIRCd.Schemas.User

  @doc """
  Handles the command.
  """
  @callback handle(user :: User.t(), arguments :: [String.t()]) :: :ok
end
