# Get Mix output sent to the current
# process to avoid polluting tests.
Mix.shell(Mix.Shell.Process)

defmodule Mix.Tasks.Db.PrepareTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Mimic

  alias Mix.Tasks.Db

  setup do
    on_exit(fn -> Db.Prepare.run(["-r"]) end)
  end

  describe "run/1" do
    test "sets up Mnesia database" do
      # deletes Mnesia schema and tables to simulate a fresh setup
      Memento.stop()
      Memento.Schema.delete([node()])

      Db.Prepare.run([])
      assert_received {:mix_shell, :info, ["Mnesia database prepared successfully."]}
    end

    test "ignores create Mnesia schema and tables if already set up" do
      Db.Prepare.run([])
      assert_received {:mix_shell, :info, ["Mnesia database prepared successfully."]}
    end

    test "recreates Mnesia database" do
      Db.Prepare.run(["--recreate"])
      assert_received {:mix_shell, :info, ["Mnesia database prepared successfully."]}

      Db.Prepare.run(["-r"])
      assert_received {:mix_shell, :info, ["Mnesia database prepared successfully."]}
    end

    test "recreates Mnesia database with short option and verbose flag" do
      Db.Prepare.run(["-r", "-v"])
      assert_received {:mix_shell, :info, ["Mnesia schema delete: :ok"]}
      assert_received {:mix_shell, :info, ["Mnesia schema create: :ok"]}
      assert_received {:mix_shell, :info, ["Mnesia start: :ok"]}
      assert_received {:mix_shell, :info, ["Mnesia table create: :ok"]}
      assert_received {:mix_shell, :info, ["Mnesia wait tables: :ok"]}
      assert_received {:mix_shell, :info, ["Mnesia database prepared successfully."]}
    end

    test "raises error if failed to create Mnesia schema" do
      Memento.Schema
      |> stub(:create, fn _nodes -> {:error, :any} end)

      assert_raise Mix.Error, "Failed to create Mnesia schema:\n:any", fn -> Db.Prepare.run([]) end
    end

    test "raises error if failed to start Mnesia" do
      Memento
      |> stub(:start, fn -> {:error, :any} end)

      assert_raise Mix.Error, "Failed to start Mnesia:\n:any", fn -> Db.Prepare.run([]) end
    end

    test "raises error if failed to create Mnesia tables" do
      Memento.Table
      |> stub(:create, fn _table -> {:error, :any} end)

      assert_raise Mix.Error, "Failed to create Mnesia table:\n:any", fn -> Db.Prepare.run([]) end
    end

    test "raises error if failed waiting for Mnesia tables" do
      Memento
      |> stub(:wait, fn _tables, _timeout -> {:error, :any} end)

      assert_raise Mix.Error, "Failed to wait for Mnesia tables:\n:any", fn -> Db.Prepare.run(["-r"]) end
    end

    test "raises error if timed out waiting for Mnesia tables" do
      Memento
      |> stub(:wait, fn _tables, _timeout -> {:timeout, []} end)

      assert_raise Mix.Error, "Timed out waiting for Mnesia tables:\n[]", fn -> Db.Prepare.run(["-r"]) end
    end
  end
end
