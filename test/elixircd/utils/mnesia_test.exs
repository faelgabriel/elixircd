defmodule ElixIRCd.Utils.MnesiaTest do
  @moduledoc false

  use ExUnit.Case, async: false
  use Mimic

  alias ElixIRCd.JobQueue
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.ChatHistory
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.SaslSession
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserMonitor
  alias ElixIRCd.Utils.Mnesia
  alias Memento.Query.Data

  import ElixIRCd.Factory

  setup do
    # The JobQueue GenServer can cause race conditions during tests due to the Jobs table,
    # so we stop it before running the tests and restart it afterward.
    Supervisor.terminate_child(ElixIRCd, JobQueue)
    on_exit(fn -> Supervisor.restart_child(ElixIRCd, JobQueue) end)

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

    test "migrates legacy registered nick rows without SCRAM or pending-email fields" do
      current_attributes = RegisteredNick.__info__().attributes
      additions = [:scram_sha_256, :pending_email, :pending_email_verify_code, :pending_email_requested_at]
      legacy_attributes = current_attributes -- additions
      account = build(:registered_nick, nickname: "Legacy", password: "correct horse battery staple")

      values =
        account
        |> Data.dump()
        |> Tuple.to_list()
        |> tl()
        |> Enum.zip(current_attributes)
        |> Map.new(fn {value, field} -> {field, value} end)

      legacy_row = List.to_tuple([RegisteredNick | Enum.map(legacy_attributes, &Map.fetch!(values, &1))])

      assert {:atomic, :ok} = :mnesia.delete_table(RegisteredNick)

      assert {:atomic, :ok} =
               :mnesia.create_table(RegisteredNick,
                 attributes: legacy_attributes,
                 disc_copies: [node()],
                 type: :set,
                 index: [:account_name_key]
               )

      assert :ok = :mnesia.wait_for_tables([RegisteredNick], 5_000)
      assert {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.write(legacy_row) end)

      assert :ok = Mnesia.upgrade_schemas()
      assert :mnesia.table_info(RegisteredNick, :attributes) == current_attributes

      Memento.transaction!(fn ->
        assert {:ok, migrated} = RegisteredNicks.get_by_nickname("Legacy")
        assert migrated.password_hash == account.password_hash
        assert migrated.scram_sha_256 == nil
        assert migrated.pending_email == nil
        assert migrated.pending_email_verify_code == nil
        assert migrated.pending_email_requested_at == nil
      end)
    end

    test "migrates legacy user, monitor and SASL session rows" do
      user = build(:user, cap_version: 302)
      monitor = build(:user_monitor, target_nick: "Target")
      session = SaslSession.new(%{user_pid: user.pid, mechanism: "PLAIN"})

      recreate_legacy_table(User, :cap_version, :set, [:nick_key, :ip_address, :identified_as_key], user)
      recreate_legacy_table(UserMonitor, :target_nick, :bag, [:target_nick_key], monitor)
      recreate_legacy_table(SaslSession, :state, :set, [], session)

      assert :ok = Mnesia.upgrade_schemas()
      assert :mnesia.table_info(User, :attributes) == User.__info__().attributes
      assert :mnesia.table_info(UserMonitor, :attributes) == UserMonitor.__info__().attributes
      assert :mnesia.table_info(SaslSession, :attributes) == SaslSession.__info__().attributes

      Memento.transaction!(fn ->
        assert Memento.Query.read(User, user.pid).cap_version == 301
        assert Memento.Query.all(UserMonitor) |> hd() |> Map.fetch!(:target_nick) == monitor.target_nick_key
        assert Memento.Query.read(SaslSession, session.user_pid).state == nil
      end)
    end

    test "fails clearly rather than guessing an unknown registered-nick schema" do
      attributes = List.delete(RegisteredNick.__info__().attributes, :email)
      assert {:atomic, :ok} = :mnesia.delete_table(RegisteredNick)

      assert {:atomic, :ok} =
               :mnesia.create_table(RegisteredNick,
                 attributes: attributes,
                 disc_copies: [node()],
                 type: :set,
                 index: [:account_name_key]
               )

      assert :ok = :mnesia.wait_for_tables([RegisteredNick], 5_000)

      assert_raise RuntimeError, ~r/RegisteredNick table has unexpected attributes/, fn ->
        Mnesia.upgrade_schemas()
      end
    end

    test "restores missing history indexes and fails clearly when a table is absent" do
      assert {:atomic, :ok} = :mnesia.del_table_index(ChatHistory, :sender_account_key)
      assert :ok = Mnesia.upgrade_schemas()

      assert {:aborted, {:already_exists, ChatHistory, _position}} =
               :mnesia.add_table_index(ChatHistory, :sender_account_key)

      assert {:atomic, :ok} = :mnesia.delete_table(ChatHistory)

      assert_raise RuntimeError, ~r/Failed adding.*ChatHistory.*index/, fn ->
        Mnesia.upgrade_schemas()
      end
    end
  end

  defp recreate_legacy_table(table, removed_field, type, indexes, record) do
    current_attributes = table.__info__().attributes
    legacy_attributes = List.delete(current_attributes, removed_field)

    values =
      record
      |> Data.dump()
      |> Tuple.to_list()
      |> tl()
      |> Enum.zip(current_attributes)
      |> Map.new(fn {value, field} -> {field, value} end)

    legacy_row = List.to_tuple([table | Enum.map(legacy_attributes, &Map.fetch!(values, &1))])
    assert {:atomic, :ok} = :mnesia.delete_table(table)

    assert {:atomic, :ok} =
             :mnesia.create_table(table,
               attributes: legacy_attributes,
               ram_copies: [node()],
               type: type,
               index: indexes
             )

    assert :ok = :mnesia.wait_for_tables([table], 5_000)
    assert {:atomic, :ok} = :mnesia.transaction(fn -> :mnesia.write(legacy_row) end)
  end
end
