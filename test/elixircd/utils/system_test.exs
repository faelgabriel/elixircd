defmodule ElixIRCd.Utils.SystemTest do
  @moduledoc false

  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias ElixIRCd.Config.Loader
  alias ElixIRCd.Utils.System

  describe "load_configurations/0" do
    test "delegates a complete configuration reload to the shared loader" do
      config = Loader.read!("config/elixircd.exs")
      expect(Config.Reader, :read!, fn "config/elixircd.exs" -> [elixircd: config] end)
      assert :ok = System.load_configurations()
    end
  end

  describe "logger_with_time/3" do
    @tag :capture_log
    test "logger_with_time logs start and finish messages" do
      log =
        capture_log(fn ->
          System.logger_with_time(:warning, "ansi color log", fn ->
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
          System.logger_with_time(
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
