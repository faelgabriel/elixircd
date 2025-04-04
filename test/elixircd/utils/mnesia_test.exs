defmodule ElixIRCd.Utils.MnesiaTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Mimic

  alias ElixIRCd.Utils.Mnesia

  setup do
    on_exit(fn -> Mnesia.setup_mnesia(recreate: true) end)
  end

  describe "setup_mnesia/1" do
    test "sets up Mnesia database" do
      # deletes Mnesia schema and tables to simulate a fresh setup
      :mnesia.stop()
      :mnesia.delete_schema([node()])

      Mnesia.setup_mnesia()
      # No error means success
    end

    test "ignores create Mnesia schema and tables if already set up" do
      Mnesia.setup_mnesia()
      # No error means success
    end

    test "recreates Mnesia database" do
      Mnesia.setup_mnesia(recreate: true)
      # No error means success
    end

    test "raises error if failed to create Mnesia schema" do
      Memento.Schema
      |> stub(:create, fn _nodes -> {:error, :any} end)

      assert_raise RuntimeError, "Failed to create Mnesia schema:\n:any", fn ->
        Mnesia.setup_mnesia()
      end
    end

    test "raises error if failed to start Mnesia" do
      Memento
      |> stub(:start, fn -> {:error, :any} end)

      assert_raise RuntimeError, "Failed to start Mnesia:\n:any", fn ->
        Mnesia.setup_mnesia()
      end
    end

    test "raises error if failed to create Mnesia tables" do
      Memento.Table
      |> stub(:create, fn _table -> {:error, :any} end)

      assert_raise RuntimeError, "Failed to create Mnesia table:\n:any", fn ->
        Mnesia.setup_mnesia()
      end
    end

    test "raises error if failed to create Mnesia disk tables" do
      Memento.Table
      |> stub(:create, fn _table -> :ok end)
      |> stub(:create, fn _table, _opts -> {:error, :disk_error} end)

      assert_raise RuntimeError, "Failed to create Mnesia disk table:\n:disk_error", fn ->
        Mnesia.setup_mnesia()
      end
    end

    test "raises error if failed waiting for Mnesia tables" do
      Memento
      |> stub(:wait, fn _tables, _timeout -> {:error, :any} end)

      assert_raise RuntimeError, "Failed to wait for Mnesia tables:\n:any", fn ->
        Mnesia.setup_mnesia(recreate: true)
      end
    end

    test "raises error if timed out waiting for Mnesia tables" do
      Memento
      |> stub(:wait, fn _tables, _timeout -> {:timeout, []} end)

      assert_raise RuntimeError, "Timed out waiting for Mnesia tables:\n[]", fn ->
        Mnesia.setup_mnesia(recreate: true)
      end
    end
  end
end
