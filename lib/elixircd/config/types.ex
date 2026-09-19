defmodule ElixIRCd.Config.Types do
  @moduledoc "Reusable value predicates for the declarative configuration schema."

  alias ElixIRCd.Utils.Validation

  @doc "Checks a scalar type without converting or substituting its value."
  @spec valid?(atom(), term()) :: boolean()
  def valid?(:boolean, value), do: is_boolean(value)
  def valid?(:positive_integer, value), do: is_integer(value) and value > 0
  def valid?(:non_negative_integer, value), do: is_integer(value) and value >= 0
  def valid?(:positive_number, value), do: is_number(value) and value > 0
  def valid?(:port, value), do: is_integer(value) and value in 1..65_535
  def valid?(:connection_limit, value), do: value == :infinity or valid?(:non_negative_integer, value)
  def valid?(:cloak_prefix, value), do: valid?(:hostname_label, value) and byte_size(value) <= 54

  def valid?(:url, value) when is_binary(value) do
    case URI.new(value) do
      {:ok, uri} ->
        valid?(:text, value) and uri.scheme in ["http", "https"] and
          valid?(:hostname, uri.host) and valid?(:port, uri.port) and is_nil(uri.userinfo) and is_nil(uri.fragment)

      {:error, _part} ->
        false
    end
  end

  def valid?(:url, _value), do: false

  def valid?(:timeout, value), do: value == :infinity or valid?(:non_negative_integer, value)

  def valid?(:text, value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != "" and not controls?(value)

  def valid?(:token, value), do: valid?(:text, value) and not String.contains?(value, [" ", ":"])
  def valid?(:path, value), do: valid?(:text, value)

  def valid?(:hostname_label, value),
    do: is_binary(value) and Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/, value)

  def valid?(:hostname, value) do
    is_binary(value) and byte_size(value) <= 253 and Enum.all?(String.split(value, "."), &valid?(:hostname_label, &1))
  end

  def valid?(:server_hostname, value), do: valid?(:hostname, value) and byte_size(value) <= 63

  def valid?(:email, value), do: valid?(:text, value) and Validation.validate_email(value) == :ok

  def valid?(:nickname, value),
    do: valid?(:text, value) and Regex.match?(~r/\A[a-zA-Z\[\]\\`_^{}|][a-zA-Z0-9\[\]\\`_^{}|-]*\z/, value)

  def valid?(:mask, value), do: valid?(:text, value) and Regex.match?(~r/\A[^\s!]+![^\s@]+@[^\s]+\z/, value)

  def valid?(:ip, value),
    do:
      is_binary(value) and String.valid?(value) and
        match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(value)))

  def valid?(:ip_tuple, value) when is_tuple(value), do: tuple_ip?(Tuple.to_list(value))
  def valid?(:ip_tuple, _value), do: false

  def valid?(:cidr, value) when is_binary(value) do
    case String.split(value, "/") do
      [address, prefix] -> valid?(:ip, address) and cidr_prefix?(address, prefix)
      _ -> false
    end
  end

  def valid?(:cidr, _value), do: false
  def valid?(:ip_or_cidr, value), do: valid?(:ip, value) or valid?(:cidr, value)

  def valid?(:channel_pattern, %Regex{} = value), do: valid_regex?(value)

  def valid?(:channel_pattern, value),
    do: valid?(:text, value) and String.starts_with?(value, ["#", "&"]) and not String.contains?(value, [" ", ","])

  def valid?(:motd, nil), do: true
  def valid?(:motd, {:ok, value}) when is_binary(value), do: valid?(:motd, value)
  def valid?(:motd, value), do: is_binary(value) and String.valid?(value) and not String.contains?(value, <<0>>)

  def valid?(:argon2_hash, value) when is_binary(value) do
    case Regex.run(
           ~r/\A\$argon2(?:id|i|d)\$v=19\$m=(\d+),t=(\d+),p=(\d+)\$([A-Za-z0-9+\/]+)\$([A-Za-z0-9+\/]+)\z/,
           value
         ) do
      [_, memory, time, parallelism, salt, digest] ->
        m = String.to_integer(memory)
        t = String.to_integer(time)
        p = String.to_integer(parallelism)

        p in 1..16 and m >= 8 * p and m <= 1_048_576 and t in 1..100 and decoded_length?(salt, 8) and
          decoded_length?(digest, 16)

      _ ->
        false
    end
  end

  def valid?(:argon2_hash, _value), do: false

  @spec valid_regex?(Regex.t()) :: boolean()
  defp valid_regex?(value) do
    is_boolean(Regex.match?(value, ""))
  rescue
    _ -> false
  end

  @spec controls?(String.t()) :: boolean()
  defp controls?(value), do: Regex.match?(~r/[\x00-\x1f\x7f]/, value)

  @spec tuple_ip?([term()]) :: boolean()
  defp tuple_ip?(parts) when length(parts) == 4, do: Enum.all?(parts, &(is_integer(&1) and &1 in 0..255))
  defp tuple_ip?(parts) when length(parts) == 8, do: Enum.all?(parts, &(is_integer(&1) and &1 in 0..65_535))
  defp tuple_ip?(_parts), do: false

  @spec cidr_prefix?(String.t(), String.t()) :: boolean()
  defp cidr_prefix?(address, prefix) do
    max_bits = if String.contains?(address, ":"), do: 128, else: 32

    case Integer.parse(prefix) do
      {bits, ""} -> bits in 0..max_bits and Integer.to_string(bits) == prefix
      _ -> false
    end
  end

  @spec decoded_length?(String.t(), pos_integer()) :: boolean()
  defp decoded_length?(value, min) do
    case Base.decode64(value, padding: false) do
      {:ok, bytes} -> byte_size(bytes) >= min
      :error -> false
    end
  end
end
