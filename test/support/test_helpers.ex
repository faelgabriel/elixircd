defmodule ElixIRCd.TestHelpers do
  @moduledoc false

  alias ElixIRCd.Data.Repo
  alias ElixIRCd.Data.Schemas
  alias Etso.Adapter.TableRegistry

  @schemas [Schemas.User, Schemas.Channel, Schemas.UserChannel]

  @doc """
  Sets up the sandbox for the test suite.
  """
  @spec setup_sandbox() :: :ok
  def setup_sandbox do
    :ok
  end

  @doc """
  Tears down the sandbox for the test suite.
  """
  @spec teardown_sandbox() :: :ok
  def teardown_sandbox do
    Enum.each(@schemas, &delete_all_objects/1)
    :ok
  end

  @spec delete_all_objects(atom) :: true
  defp delete_all_objects(schema) do
    {:ok, table} = TableRegistry.get_table(Repo, schema)
    :ets.delete_all_objects(table)
  end
end
