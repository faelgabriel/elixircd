defmodule ElixIRCd.Data.Types.TransportTypeTest do
  @moduledoc false

  use ExUnit.Case, async: true
  doctest ElixIRCd.Data.Types.TransportType

  alias ElixIRCd.Data.Types.TransportType

  describe "type/0" do
    test "returns :string" do
      assert TransportType.type() == :string
    end
  end

  describe "cast/1" do
    test "casts valid transport types" do
      assert {:ok, :ranch_tcp} == TransportType.cast(:ranch_tcp)
      assert {:ok, :ranch_ssl} == TransportType.cast(:ranch_ssl)
    end

    test "returns :error for invalid transport types" do
      assert :error == TransportType.cast(:invalid_transport)
    end
  end

  describe "load/1" do
    test "loads valid transport strings" do
      assert {:ok, :ranch_tcp} == TransportType.load("ranch_tcp")
      assert {:ok, :ranch_ssl} == TransportType.load("ranch_ssl")
    end

    test "returns :error for invalid transport strings" do
      assert :error == TransportType.load("invalid_transport")
    end
  end

  describe "dump/1" do
    test "dumps valid transport types" do
      assert {:ok, "ranch_tcp"} == TransportType.dump(:ranch_tcp)
      assert {:ok, "ranch_ssl"} == TransportType.dump(:ranch_ssl)
    end

    test "returns :error for invalid transport types" do
      assert :error == TransportType.dump(:invalid_transport)
    end
  end

  describe "embed_as/1" do
    test "always returns :self" do
      assert :self == TransportType.embed_as(:json)
      assert :self == TransportType.embed_as(:atom)
    end
  end

  describe "equal?/2" do
    test "returns true for equal transport types" do
      assert TransportType.equal?(:ranch_tcp, :ranch_tcp)
      assert TransportType.equal?(:ranch_ssl, :ranch_ssl)
    end

    test "returns false for non-equal transport types" do
      refute TransportType.equal?(:ranch_tcp, :ranch_ssl)
      refute TransportType.equal?(:ranch_ssl, :ranch_tcp)
    end

    test "returns false for nil comparisons" do
      refute TransportType.equal?(nil, :ranch_tcp)
      refute TransportType.equal?(:ranch_tcp, nil)
    end
  end
end
