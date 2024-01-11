defmodule ElixIRCd.DataCase do
  @moduledoc """
  This module defines the base test case for data tests.
  """

  use ExUnit.CaseTemplate

  alias ElixIRCd.Data.Repo
  alias ElixIRCd.Data.Schemas
  alias Etso.Adapter.TableRegistry

  @schemas [
    Schemas.User,
    Schemas.Channel,
    Schemas.UserChannel
  ]

  setup do
    on_exit(fn -> Enum.each(@schemas, &delete_all_ets_objects/1) end)
  end

  @spec delete_all_ets_objects(atom) :: true
  # Currently, the Etso adapter lacks sandboxing capabilities for tables.
  # Therefore, we need to manually clear all objects from the ETS table.
  defp delete_all_ets_objects(schema) do
    {:ok, table} = TableRegistry.get_table(Repo, schema)
    :ets.delete_all_objects(table)
  end
end
