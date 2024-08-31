defmodule ElixIRCd.UtilsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ElixIRCd.Utils

  describe "logger_with_time/3" do
    @tag :capture_log
    test "logger_with_time logs start and finish messages" do
      log =
        capture_log(fn ->
          Utils.logger_with_time(:warning, "ansi color log", fn ->
            :timer.sleep(70)
            "colorful result"
          end)
        end)

      assert log =~ "[warning]"
      assert log =~ "Starting ansi color log"
      assert log =~ "Finished ansi color log in"
      assert log =~ "ms"
    end
  end

  describe "logger_with_time/4" do
    @tag :capture_log
    test "logger_with_time logs start and finish messages" do
      log =
        capture_log(fn ->
          Utils.logger_with_time(
            :warning,
            "ansi color log",
            fn ->
              :timer.sleep(70)
              "colorful result"
            end,
            ansi_color: :yellow
          )
        end)

      assert log =~ "[warning]"
      assert log =~ "Starting ansi color log"
      assert log =~ "Finished ansi color log in"
      assert log =~ "ms"
    end
  end
end
