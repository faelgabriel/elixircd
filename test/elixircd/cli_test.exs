defmodule ElixIRCd.CLITest do
  @moduledoc false

  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO

  alias ElixIRCd.CLI

  test "root help describes project commands" do
    for args <- [[], ["help"], ["--help"], ["-h"]] do
      assert {:ok, output} = CLI.run(args)
      assert output =~ "Usage: elixircd COMMAND [ARGS]"
      assert output =~ "oper  Manage IRC operators"
      refute output =~ "Release commands:"
      refute output =~ "rpc EXPR"
    end
  end

  test "dispatches operator help and reports unknown commands" do
    assert {:ok, output} = CLI.run(["oper", "help", "passwd"])
    assert output =~ "Usage: elixircd oper passwd NAME"
    assert CLI.run(["help", "oper", "passwd"]) == {:ok, output}

    assert {:error, error} = CLI.run(["help", "start", "extra"])
    assert error =~ "Unknown command: start"

    assert {:error, error} = CLI.run(["start"])
    assert error =~ "Unknown command: start"

    assert {:error, error} = CLI.run(["help", "unknown"])
    assert error =~ "Unknown command: unknown"

    assert {:error, error} = CLI.run(["unknown"])
    assert error =~ "Unknown command: unknown"
    assert error =~ "Usage: elixircd COMMAND [ARGS]"
  end

  test "main prints success and failure to the correct streams with exit codes" do
    stub(System, :halt, fn code -> throw({:halt, code}) end)

    output = capture_io(fn -> assert catch_throw(CLI.main(["help"])) == {:halt, 0} end)
    assert output =~ "Usage: elixircd COMMAND [ARGS]"

    error = capture_io(:stderr, fn -> assert catch_throw(CLI.main(["unknown"])) == {:halt, 1} end)
    assert error =~ "Unknown command: unknown"
  end
end
