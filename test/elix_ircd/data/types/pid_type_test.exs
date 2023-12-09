defmodule ElixIRCd.Types.PidTypeTest do
  @moduledoc false

  use ExUnit.Case, async: true
  doctest ElixIRCd.Types.PidType

  alias ElixIRCd.Types.PidType

  setup do
    {:ok, pid: self()}
  end

  describe "type/0" do
    test "returns :pid" do
      assert PidType.type() == :pid
    end
  end

  describe "cast/1" do
    test "casts a valid pid", %{pid: pid} do
      assert {:ok, ^pid} = PidType.cast(pid)
    end

    test "returns :error for invalid input" do
      invalid_input = "not_a_pid"
      assert :error == PidType.cast(invalid_input)
    end
  end

  describe "load/1" do
    test "loads a valid pid", %{pid: pid} do
      assert {:ok, ^pid} = PidType.load(pid)
    end

    test "returns :error for invalid input" do
      invalid_input = "not_a_pid"
      assert :error == PidType.load(invalid_input)
    end
  end

  describe "dump/1" do
    test "dumps a valid pid", %{pid: pid} do
      assert {:ok, ^pid} = PidType.dump(pid)
    end

    test "returns :error for invalid input" do
      invalid_input = "not_a_pid"
      assert :error == PidType.dump(invalid_input)
    end
  end

  describe "embed_as/1" do
    test "always returns :self" do
      assert :self == PidType.embed_as(:json)
      assert :self == PidType.embed_as(:atom)
    end
  end

  describe "equal?/2" do
    test "returns true for equal pids", %{pid: pid} do
      assert PidType.equal?(pid, pid)
    end

    test "returns false for non-equal pids", %{pid: pid} do
      another_pid = spawn(fn -> :ok end)
      refute PidType.equal?(pid, another_pid)
    end
  end
end
