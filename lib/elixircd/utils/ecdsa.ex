defmodule ElixIRCd.Utils.Ecdsa do
  @moduledoc """
  Helpers for validating compressed NIST P-256 public keys.

  OTP accepts some malformed compressed points when they are passed directly
  to low-level ECDH functions, so callers must validate the curve equation
  before using a key for authentication.
  """

  @p256_prime 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
  @p256_a @p256_prime - 3
  @p256_b 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B

  @doc "Checks that a compressed public key represents a point on NIST P-256."
  @spec valid_compressed_p256_public_key?(binary()) :: boolean()
  def valid_compressed_p256_public_key?(<<prefix, x_bytes::binary-size(32)>>)
      when prefix in [2, 3] do
    x = :binary.decode_unsigned(x_bytes)

    if x < @p256_prime do
      rhs = rem(x * x * x + @p256_a * x + @p256_b, @p256_prime)
      y = modular_pow(rhs, div(@p256_prime + 1, 4), @p256_prime)

      rem(y * y, @p256_prime) == rhs and (y != 0 or prefix == 2)
    else
      false
    end
  end

  def valid_compressed_p256_public_key?(_public_key), do: false

  @spec modular_pow(non_neg_integer(), non_neg_integer(), pos_integer()) :: non_neg_integer()
  defp modular_pow(base, exponent, modulus) do
    modular_pow(rem(base, modulus), exponent, modulus, 1)
  end

  @spec modular_pow(non_neg_integer(), non_neg_integer(), pos_integer(), non_neg_integer()) :: non_neg_integer()
  defp modular_pow(_base, 0, _modulus, result), do: result

  defp modular_pow(base, exponent, modulus, result) do
    next_result = if rem(exponent, 2) == 1, do: rem(result * base, modulus), else: result
    modular_pow(rem(base * base, modulus), div(exponent, 2), modulus, next_result)
  end
end
