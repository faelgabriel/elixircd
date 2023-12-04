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
    setup_sandbox()
    on_exit(fn -> teardown_sandbox() end)
  end

  @spec setup_sandbox() :: :ok
  defp setup_sandbox do
    :ok
  end

  @spec teardown_sandbox() :: :ok
  defp teardown_sandbox do
    Enum.each(@schemas, &delete_all_ets_objects/1)
    :ok
  end

  @spec delete_all_ets_objects(atom) :: true
  # Etso adapter does not have a way to sandbox the tables,
  # so we have to delete all objects in the ETS table.
  defp delete_all_ets_objects(schema) do
    {:ok, table} = TableRegistry.get_table(Repo, schema)
    :ets.delete_all_objects(table)
  end
end
