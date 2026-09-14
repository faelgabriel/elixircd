defmodule ElixIRCd.Utils.SystemTest do
  @moduledoc false

  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias ElixIRCd.Utils.HostnameCloaking
  alias ElixIRCd.Utils.System

  describe "load_configurations/0" do
    test "loads and merges the configuration" do
      before_config = Application.get_all_env(:elixircd)
      on_exit(fn -> Application.put_all_env(elixircd: before_config) end)

      expect(Config.Reader, :read!, fn "config/elixircd.exs" ->
        [elixircd: [server: [name: "Test Network"], cloaking: [cloak_key_file: "data/test-cloak.key"]]]
      end)

      expect(HostnameCloaking, :load_key, fn "data/test-cloak.key" -> :ok end)

      assert :ok = System.load_configurations()
      assert Application.get_env(:elixircd, :cloaking)[:cloak_key_file] == "data/test-cloak.key"
      server = Application.get_env(:elixircd, :server)
      assert server[:name] == "Test Network"
      assert Keyword.delete(server, :name) == Keyword.delete(before_config[:server], :name)
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
