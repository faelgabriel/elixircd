defmodule Mix.Tasks.Db.SetupTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mimic

  alias Mix.Tasks.Db.Setup

  setup do
    on_exit(fn ->
      capture_io(fn -> Setup.run(["-r"]) end)
    end)
  end

  describe "run/1" do
    test "sets up Mnesia database" do
      Memento.stop()
      Memento.Schema.delete([node()])

      assert capture_io(fn ->
               assert :ok = Setup.run([])
             end) =~ "Mnesia database created successfully."
    end

    test "recreates Mnesia database" do
      assert capture_io(fn ->
               assert :ok = Setup.run(["--recreate"])
             end) =~ "Mnesia database recreated successfully."

      assert capture_io(fn ->
               assert :ok = Setup.run(["-r"])
             end) =~ "Mnesia database recreated successfully."
    end

    test "recreates Mnesia database with short option and verbose flag" do
      Memento.start()

      assert capture_io(fn ->
               assert :ok = Setup.run(["-r", "-v"])
             end) ==
               "Mnesia stop: :ok\nMnesia schema delete: :ok\nMnesia schema create: :ok\nMnesia start: :ok\nMnesia table create: :ok\nMnesia wait tables: :ok\nMnesia database recreated successfully.\n"
    end

    test "raises error if database already exists" do
      assert_raise Mix.Error,
                   "Failed to create Mnesia schema. Database already exists.\nUse -r or --recreate to recreate the database.",
                   fn -> Setup.run([]) end
    end

    test "raises error if failed to create Mnesia schema" do
      Memento.Schema
      |> stub(:create, fn _nodes -> {:error, {:badarg}} end)

      assert_raise Mix.Error,
                   "Failed to create Mnesia schema. Error:\n{:badarg}",
                   fn -> Setup.run([]) end
    end

    test "raises error if failed waiting for Mnesia tables" do
      Memento
      |> stub(:wait, fn _tables, _timeout -> {:error, :any} end)

      assert_raise Mix.Error,
                   "Failed to wait for Mnesia tables. Error:\n{:error, :any}",
                   fn -> Setup.run(["-r"]) end
    end
  end
end
