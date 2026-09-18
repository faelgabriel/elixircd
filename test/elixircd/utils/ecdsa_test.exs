defmodule ElixIRCd.Utils.EcdsaTest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Utils.Ecdsa

  test "accepts generated compressed P-256 public keys" do
    {public_key, _private_key} = :crypto.generate_key(:ecdh, :secp256r1)

    assert Ecdsa.valid_compressed_p256_public_key?(compress_public_key(public_key))
  end

  test "rejects malformed, out-of-range, and non-curve points" do
    refute Ecdsa.valid_compressed_p256_public_key?(<<2, 1, 2>>)
    refute Ecdsa.valid_compressed_p256_public_key?(<<4, 0::256>>)
    refute Ecdsa.valid_compressed_p256_public_key?(<<2>> <> :binary.copy(<<255>>, 32))
    refute Ecdsa.valid_compressed_p256_public_key?(<<2, 2, 0::248>>)
  end

  defp compress_public_key(<<_prefix, x::binary-size(32), y::binary-size(32)>>) do
    prefix = if rem(:binary.last(y), 2) == 1, do: 3, else: 2
    <<prefix, x::binary>>
  end
end
