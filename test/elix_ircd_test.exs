defmodule ElixIRCdTest do
  @moduledoc false
  use ExUnit.Case, async: true
  doctest ElixIRCd

  alias ExUnit.CaptureLog

  test "ensures the application starts and stops" do
    # Starts the application
    assert {:ok, _} = Application.ensure_all_started(:elixircd)

    # Stops the application
    log = CaptureLog.capture_log(fn -> Application.stop(:elixircd) end)
    assert String.contains?(log, "Server shutting down...")
  end
end
