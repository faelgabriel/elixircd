defmodule ElixIRCd.Utils.TimeTest do
  @moduledoc false

  use ExUnit.Case

  alias ElixIRCd.Utils.Time

  describe "format_time/1" do
    test "returns formatted time string" do
      assert Time.format_time(~U[2021-01-01 00:00:00Z]) == "2021-01-01 00:00:00"
    end

    test "returns '(unknown)' for nil" do
      assert Time.format_time(nil) == "(unknown)"
    end
  end
end
