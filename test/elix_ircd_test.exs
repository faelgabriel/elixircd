defmodule ElixIRCdTest do
  @moduledoc false

  use ExUnit.Case
  doctest ElixIRCd

  describe "start/2" do
    test "starts the application" do
      # Just in case the application is already running
      Application.stop(:elixircd)

      assert :ok = Application.start(:elixircd, :permanent)
    end
  end

  describe "stop/1" do
    test "stops the application" do
      # Just in case the application is not running
      Application.ensure_all_started(:elixircd)

      assert :ok = Application.stop(:elixircd)
    end
  end
end
