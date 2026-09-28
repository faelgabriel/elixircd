defmodule ElixIRCd.Operators.CLITest do
  @moduledoc false

  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO

  alias ElixIRCd.Operators

  setup do
    original_node = System.get_env("RELEASE_NODE")
    original_distribution = System.get_env("RELEASE_DISTRIBUTION")
    System.put_env("RELEASE_NODE", "custom@127.0.0.1")
    System.put_env("RELEASE_DISTRIBUTION", "name")

    on_exit(fn ->
      if original_node,
        do: System.put_env("RELEASE_NODE", original_node),
        else: System.delete_env("RELEASE_NODE")

      if original_distribution,
        do: System.put_env("RELEASE_DISTRIBUTION", original_distribution),
        else: System.delete_env("RELEASE_DISTRIBUTION")
    end)

    stub(Node, :start, fn cli_node, name_domain: :longnames ->
      assert Atom.to_string(cli_node) =~ ~r/^elixircd-oper-cli-[0-9a-f]{8}@127\.0\.0\.1$/
      {:ok, self()}
    end)

    stub(Node, :connect, fn server_node ->
      assert server_node == :"custom@127.0.0.1"
      true
    end)

    :ok
  end

  test "hash prompts for a confirmed password without requiring a running server" do
    output =
      capture_io("a-long-password\na-long-password\n", fn ->
        assert {:ok, hash} = Operators.CLI.run(["hash"])
        assert Argon2.verify_pass("a-long-password", hash)
      end)

    assert output == ""
  end

  test "password input rejects short, mismatched, and missing input" do
    capture_io("short\n", fn ->
      assert {:error, message} = Operators.CLI.run(["hash"])
      assert message =~ "at least 12 bytes"
    end)

    capture_io("a-long-password\nwrong-password\n", fn ->
      assert {:error, message} = Operators.CLI.run(["hash"])
      assert message =~ "match confirmation"
    end)

    capture_io("", fn ->
      assert {:error, "Could not read a password from the terminal"} = Operators.CLI.run(["hash"])
    end)
  end

  test "list reports both sources without hashes and handles an empty registry" do
    stub(Operators.Remote, :call, fn :"custom@127.0.0.1", :list, [] ->
      [{"static", :config, true}, {"managed", :database, false}, {"active", :database, true}]
    end)

    assert {:ok, "static (config file; read-only)\nmanaged (database; disabled)\nactive (database; enabled)"} =
             Operators.CLI.run(["list"])

    stub(Operators.Remote, :call, fn :"custom@127.0.0.1", :list, [] -> [] end)
    assert {:ok, "No operators configured"} = Operators.CLI.run(["list"])

    stub(Operators.Remote, :call, fn :"custom@127.0.0.1", :list, [] -> {:badrpc, :nodedown} end)
    assert {:error, message} = Operators.CLI.run(["list"])
    assert message =~ "server availability"
  end

  test "uses the configured release node name and host without a CLI argument" do
    System.put_env("RELEASE_NODE", "irc-prod@localhost")

    stub(Node, :start, fn cli_node, name_domain: :longnames ->
      assert Atom.to_string(cli_node) =~ ~r/^elixircd-oper-cli-[0-9a-f]{8}@localhost$/
      {:ok, self()}
    end)

    stub(Node, :connect, fn server_node -> server_node == :"irc-prod@localhost" end)
    stub(Operators.Remote, :call, fn :"irc-prod@localhost", :list, [] -> [] end)
    assert {:ok, "No operators configured"} = Operators.CLI.run(["list"])
  end

  test "uses the release's default short node name and local hostname" do
    {:ok, host_chars} = :inet.gethostname()
    host = List.to_string(host_chars)
    server_node = String.to_atom("elixircd@#{host}")
    System.put_env("RELEASE_NODE", "elixircd")
    System.put_env("RELEASE_DISTRIBUTION", "sname")

    stub(Node, :start, fn cli_node, name_domain: :shortnames ->
      assert Atom.to_string(cli_node) =~ ~r/^elixircd-oper-cli-[0-9a-f]{8}$/
      {:ok, self()}
    end)

    stub(Node, :connect, fn node -> node == server_node end)
    stub(Operators.Remote, :call, fn ^server_node, :list, [] -> [] end)
    assert {:ok, "No operators configured"} = Operators.CLI.run(["list"])

    System.put_env("RELEASE_NODE", "elixircd@localhost")
    localhost_node = :elixircd@localhost
    stub(Node, :connect, fn node -> node == localhost_node end)
    stub(Operators.Remote, :call, fn ^localhost_node, :list, [] -> [] end)
    assert {:ok, "No operators configured"} = Operators.CLI.run(["list"])
  end

  test "add and passwd send only the hash to the server" do
    stub(Operators.Remote, :call, fn :"custom@127.0.0.1", action, ["alice", hash] ->
      assert action in [:add, :rotate]
      assert Argon2.verify_pass("a-long-password", hash)
      :ok
    end)

    for action <- ["add", "passwd"] do
      capture_io("a-long-password\na-long-password\n", fn ->
        assert Operators.CLI.run([action, "alice"]) == {:ok, "Operator alice: #{action} completed"}
      end)
    end
  end

  test "management actions report success and sanitized errors" do
    stub(Operators.Remote, :call, fn :"custom@127.0.0.1", action, ["alice"] ->
      assert action in [:disable, :enable, :remove]
      :ok
    end)

    for action <- ["disable", "enable", "remove"] do
      assert Operators.CLI.run([action, "alice"]) == {:ok, "Operator alice: #{action} completed"}
    end

    for {reason, message} <- [
          configured: "managed in config",
          exists: "already exists",
          not_found: "not found",
          invalid_name: "Invalid operator name",
          invalid_hash: "Invalid Argon2",
          unexpected: "operation failed"
        ] do
      stub(Operators.Remote, :call, fn :"custom@127.0.0.1", :remove, ["alice"] -> {:error, reason} end)
      assert {:error, text} = Operators.CLI.run(["remove", "alice"])
      assert text =~ message
    end

    stub(Operators.Remote, :call, fn :"custom@127.0.0.1", :remove, ["alice"] -> {:badrpc, :nodedown} end)
    assert {:error, message} = Operators.CLI.run(["remove", "alice"])
    assert message =~ "server availability"
  end

  test "connection failures and invalid commands return actionable errors" do
    assert {:ok, message} = Operators.CLI.run([])
    assert message =~ "Usage:"

    System.put_env("RELEASE_NODE", "invalid@")
    assert {:error, message} = Operators.CLI.run(["list"])
    assert message =~ "Cannot connect"

    System.delete_env("RELEASE_NODE")
    assert {:error, message} = Operators.CLI.run(["list"])
    assert message =~ "Cannot connect"

    System.put_env("RELEASE_NODE", "custom@127.0.0.1")

    System.put_env("RELEASE_DISTRIBUTION", "none")
    assert {:error, message} = Operators.CLI.run(["list"])
    assert message =~ "Cannot connect"
    System.put_env("RELEASE_DISTRIBUTION", "name")

    stub(Node, :connect, fn _ -> false end)
    assert {:error, message} = Operators.CLI.run(["list"])
    assert message =~ "Cannot connect"

    stub(Node, :start, fn _, _ -> {:error, :already_started} end)
    assert {:error, message} = Operators.CLI.run(["list"])
    assert message =~ "Cannot connect"
  end

  test "operator help is available without a server and documents every command" do
    for args <- [[], ["help"], ["--help"], ["-h"]] do
      assert {:ok, output} = Operators.CLI.run(args)
      assert output =~ "Usage: elixircd oper COMMAND [ARGS]"

      for command <- ["list", "add", "passwd", "disable", "enable", "remove", "hash"] do
        assert output =~ command
      end
    end

    assert {:ok, output} = Operators.CLI.run(["help", "add"])
    assert output =~ "Usage: elixircd oper add NAME"
    assert output =~ "never accepted as arguments"
    assert Operators.CLI.run(["add", "--help"]) == {:ok, output}

    assert {:error, error} = Operators.CLI.run(["help", "unknown"])
    assert error =~ "Unknown operator command"

    assert {:error, error} = Operators.CLI.run(["add", "alice", "password"])
    assert error =~ "Invalid operator command or arguments"
  end
end
