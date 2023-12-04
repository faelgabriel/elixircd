defmodule ElixIRCd.DataCase do
  @moduledoc """
  This module defines the base test case for data tests.
  """

  use ExUnit.CaseTemplate

  alias ElixIRCd.TestHelpers

  setup do
    TestHelpers.setup_sandbox()
    on_exit(fn -> TestHelpers.teardown_sandbox() end)
  end
end
