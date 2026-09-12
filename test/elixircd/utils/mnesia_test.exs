defmodule ElixIRCd.Utils.MnesiaTest do
  @moduledoc false

  use ExUnit.Case, async: false
  use Mimic

  alias ElixIRCd.JobQueue
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Mnesia

  setup do
    # The JobQueue GenServer can cause race conditions during tests due to the Jobs table,
    # so we stop it before running the tests and restart it afterward.
    Supervisor.terminate_child(ElixIRCd, JobQueue)
    on_exit(fn -> Supervisor.restart_child(ElixIRCd, JobQueue) end)

    on_exit(fn -> Mnesia.setup_mnesia(recreate: true) end)
  end

  test "upgrades the previous User schema for CAP version tracking" do
    user_table = User
    current = user_table.__info__().attributes
    old = List.delete(current, :cap_version)

    transform = fn row ->
      values = current |> Enum.zip(tl(Tuple.to_list(row))) |> Map.new()
      List.to_tuple([user_table | Enum.map(old, &Map.fetch!(values, &1))])
    end

    user =
      Memento.transaction!(fn ->
        Users.create(%{
          pid: self(),
          transport: :tcp,
          ip_address: {127, 0, 0, 1},
          port_connected: 6667,
          nick: "ExistingUser"
        })
      end)

    # Keep the live row while exercising the startup schema upgrade.
    stub(Memento, :stop, fn -> :ok end)
    stub(Memento, :start, fn -> :ok end)
    {:atomic, :ok} = :mnesia.transform_table(user_table, transform, old)
    Mnesia.setup_mnesia()
    assert :mnesia.table_info(user_table, :attributes) == current

    Memento.transaction!(fn ->
      {:ok, migrated} = Users.get_by_pid(user.pid)
      assert migrated.nick == "ExistingUser"
      assert migrated.cap_version == 301
      Users.delete(migrated)
    end)
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
