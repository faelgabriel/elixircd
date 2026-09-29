defmodule ElixIRCd.CLITest do
  @moduledoc false

  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO

  alias ElixIRCd.CLI
  alias ElixIRCd.CLI.Config
  alias ElixIRCd.CLI.Rehash
  alias ElixIRCd.CLI.Remote
  alias ElixIRCd.Commands.Rehash, as: RehashCommand
  alias ElixIRCd.Config.Error
  alias ElixIRCd.Config.Loader

  test "root help describes project commands" do
    for args <- [[], ["help"], ["--help"], ["-h"]] do
      assert {:ok, output} = CLI.run(args)
      assert output =~ "Usage: elixircd COMMAND [ARGS]"
      assert output =~ "oper  Manage IRC operators"
      assert output =~ "config  Check configuration"
      assert output =~ "rehash  Reload running server configuration"
      refute output =~ "Release commands:"
      refute output =~ "rpc EXPR"
    end
  end

  test "checks the release configuration without contacting the running server" do
    expect(Loader, :check!, fn "config/elixircd.exs" -> :ok end)
    reject(Remote, :connect, 1)
    assert CLI.run(["config", "check"]) == {:ok, "Configuration is valid"}

    expect(Loader, :check!, fn "config/elixircd.exs" ->
      raise Error, path: "config/elixircd.exs", errors: ["elixircd.server.hostname: expected string"]
    end)

    assert {:error, message} = CLI.run(["config", "check"])
    assert message =~ "elixircd.server.hostname: expected string"
  end

  test "config check reports unexpected evaluation failures without their contents" do
    expect(Loader, :check!, fn "config/elixircd.exs" -> raise "secret value" end)
    assert {:error, message} = Config.run(["check"])
    refute message =~ "secret value"
  end

  test "rehash reports remote success, validation failure, and unavailable server" do
    stub(Remote, :connect, fn "rehash" -> {:ok, :elixircd@localhost} end)

    stub(Remote, :call, fn :elixircd@localhost, RehashCommand, :run_cli, [] -> :ok end)
    assert CLI.run(["rehash"]) == {:ok, "Configuration reloaded"}

    stub(Remote, :call, fn :elixircd@localhost, RehashCommand, :run_cli, [] ->
      {:error, %Error{path: "config/elixircd.exs", errors: ["elixircd.listeners: change requires server restart"]}}
    end)

    assert {:error, message} = Rehash.run([])
    assert message =~ "change requires server restart"

    stub(Remote, :call, fn :elixircd@localhost, RehashCommand, :run_cli, [] -> {:badrpc, :nodedown} end)
    assert {:error, message} = Rehash.run([])
    assert message =~ "server logs"

    stub(Remote, :connect, fn "rehash" -> {:error, "Cannot connect to the running ElixIRCd node"} end)
    assert {:error, message} = Rehash.run([])
    assert message =~ "Cannot connect"
  end

  test "new commands expose help and reject extra arguments" do
    assert {:ok, help} = CLI.run(["help", "rehash"])
    assert help =~ "Usage: elixircd rehash"
    assert {:ok, help} = CLI.run(["help", "config"])
    assert help =~ "Usage: elixircd config check"
    assert {:error, _} = CLI.run(["rehash", "unexpected"])
    assert {:error, _} = CLI.run(["config", "unexpected"])
  end

  test "remote RPC reports an unavailable release" do
    assert match?(
             {:badrpc, _},
             Remote.call(:"elixircd-test-unavailable@127.0.0.1", RehashCommand, :run_cli, [])
           )
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
