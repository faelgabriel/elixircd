defmodule ElixIRCd.Types.PortTypeTest do
  @moduledoc false

  use ExUnit.Case, async: true
  doctest ElixIRCd.Types.PortType

  alias ElixIRCd.Types.PortType

  setup do
    {:ok, port: Port.open({:spawn, "cat /dev/null"}, [:binary])}
  end

  describe "type/0" do
    test "returns :port" do
      assert PortType.type() == :port
    end
  end

  describe "cast/1" do
    test "casts a valid port", %{port: port} do
      assert {:ok, ^port} = PortType.cast(port)
    end

    test "returns :error for invalid input" do
      invalid_input = "not_a_port"
      assert :error == PortType.cast(invalid_input)
    end
  end

  describe "load/1" do
    test "loads a valid port", %{port: port} do
      assert {:ok, ^port} = PortType.load(port)
    end

    test "returns :error for invalid input" do
      invalid_input = "not_a_port"
      assert :error == PortType.load(invalid_input)
    end
  end

  describe "dump/1" do
    test "dumps a valid port", %{port: port} do
      assert {:ok, ^port} = PortType.dump(port)
    end

    test "returns :error for invalid input" do
      invalid_input = "not_a_port"
      assert :error == PortType.dump(invalid_input)
    end
  end

  describe "embed_as/1" do
    test "always returns :self" do
      assert :self == PortType.embed_as(:json)
      assert :self == PortType.embed_as(:atom)
    end
  end

  describe "equal?/2" do
    test "returns true for equal ports", %{port: port} do
      assert PortType.equal?(port, port)
    end

    test "returns false for non-equal ports", %{port: port} do
      another_port = Port.open({:spawn, "cat /dev/null"}, [:binary])
      refute PortType.equal?(port, another_port)
      Port.close(another_port)
    end
  end
end
