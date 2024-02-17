defmodule ElixIRCd.DataCase do
  @moduledoc """
  This module defines the base test case for data tests.
  """

  use ExUnit.CaseTemplate

  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel

  @tables [
    Channel,
    User,
    UserChannel
  ]

  setup tags do
    unless tags[:async] do
      Enum.each(@tables, &Memento.Table.clear/1)
      Memento.wait(@tables)
    end

    :ok
  end
end
