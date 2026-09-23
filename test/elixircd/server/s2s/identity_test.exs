defmodule ElixIRCd.Server.S2S.IdentityTest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Server.S2S.Identity

  test "generated IDs are canonical 128-bit base32 values" do
    id = Identity.new_id()

    assert byte_size(id) == 26
    assert Identity.valid_id?(id)
    assert {:ok, <<_::binary-size(16)>>} = Identity.decode_id(id)
    refute Identity.valid_id?(String.downcase(id))
    refute Identity.valid_id?(id <> "=")
  end

  test "rejects non-zero unused base32 bits" do
    id = Identity.new_id()
    invalid = binary_part(id, 0, 25) <> "B"

    refute Identity.valid_id?(invalid)
    assert {:error, :noncanonical} = Identity.decode_id(invalid)
  end

  test "stamp order is counter, sid, then boot" do
    boot = Identity.boot()

    assert Identity.compare_stamp([2, "a", boot], [1, "z", boot]) == :gt
    assert Identity.compare_stamp([2, "a", boot], [2, "b", boot]) == :lt
    assert Identity.compare_stamp([2, "a", boot], [2, "a", boot]) == :eq
  end

  test "edge identity uses sorted hello tuples and compact JSON" do
    left = %{"sid" => "alpha", "boot" => Identity.boot(), "nonce" => Identity.nonce()}
    right = %{"sid" => "beta", "boot" => Identity.boot(), "nonce" => Identity.nonce()}

    assert {:ok, first} = Identity.edge_id(left, right)
    assert {:ok, second} = Identity.edge_id(right, left)
    assert first == second
    assert byte_size(first) == 64
  end
end
