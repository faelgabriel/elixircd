defmodule ElixIRCd.Server.S2S.JSONTest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Server.S2S.JSON

  test "rejects duplicate keys before decoding" do
    assert {:error, :duplicate_json_key} = JSON.scan(~s({"a":1,"a":2}))
    assert {:error, :duplicate_json_key} = JSON.decode_object(~s({"a":1,"a":2}))
  end

  test "rejects trailing values and non-integer JSON number forms" do
    assert {:error, :trailing_json_data} = JSON.scan("true false")
    assert {:error, :fractional_number} = JSON.scan(~s({"n":1.0}))
    assert {:error, :negative_number} = JSON.scan(~s({"n":-1}))
    assert {:error, :exponent_number} = JSON.scan(~s({"n":1e3}))
    assert {:error, :invalid_json_value} = JSON.scan(~s({"n":+1}))
  end

  test "rejects integers outside the exact ENP JSON range" do
    assert :ok = JSON.scan(~s({"n":9007199254740991}))
    assert {:error, :integer_overflow} = JSON.scan(~s({"n":9007199254740992}))
    assert {:error, :integer_overflow} = JSON.scan(~s({"n":12345678901234567890}))
  end

  test "enforces depth and aggregate value budgets" do
    assert {:error, :json_depth_exceeded} = JSON.scan("[[[0]]]", max_depth: 1)
    assert {:error, :json_values_exceeded} = JSON.scan("[0,1,2]", max_values: 2)
  end

  test "encodes compact binary JSON" do
    encoded = JSON.encode(%{"b" => 2, "a" => [true, nil]})

    assert is_binary(encoded)
    assert {:ok, %{"a" => [true, nil], "b" => 2}} = JSON.decode_object(encoded)
  end
end
