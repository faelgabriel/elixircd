defmodule ElixIRCd.DataCase do
  @moduledoc """
  This module defines the base test case for data tests.
  """

  use ExUnit.CaseTemplate

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
    :ok
  end
end
