defmodule ElixIRCd.Utils.HostnameCloaking do
  @moduledoc """
  Hostname cloaking utilities using HMAC-SHA256 for secure, deterministic hashing.
  """

  import ElixIRCd.Utils.Network, only: [format_ip_address: 1]

  @doc """
  Generates a cloaked hostname based on IP address and hostname.
  """
  @spec cloak(:inet.ip_address(), String.t() | nil) :: String.t()
  def cloak(ip_address, hostname) do
    case has_resolved_hostname?(ip_address, hostname) do
      true -> cloak_hostname(hostname)
      false -> cloak_ip_address(ip_address)
    end
  end

  @spec has_resolved_hostname?(:inet.ip_address(), String.t() | nil) :: boolean()
  defp has_resolved_hostname?(_ip_address, nil), do: false

  defp has_resolved_hostname?(ip_address, hostname) when is_binary(hostname) do
    formatted_ip = format_ip_address(ip_address)
    hostname != formatted_ip
  end

  @spec cloak_hostname(String.t()) :: String.t()
  defp cloak_hostname(hostname) when is_binary(hostname) do
    parts = String.split(hostname, ".")
    domain_parts_to_keep = Application.get_env(:elixircd, :cloaking)[:cloak_domain_parts]

    case length(parts) do
      n when n > domain_parts_to_keep ->
        {to_hash, to_keep} = Enum.split(parts, -domain_parts_to_keep)
        hashed = hash_hostname_segments(to_hash)
        prefix = Application.get_env(:elixircd, :cloaking)[:cloak_prefix]
        "#{prefix}-#{hashed}.#{Enum.join(to_keep, ".")}"

      _ ->
        cloak_short_hostname(hostname)
    end
  end

  @spec cloak_ip_address(:inet.ip_address()) :: String.t()
  defp cloak_ip_address({a, b, c, d}) do
    segment1 = hash_ipv4_segment([a, b])
    segment2 = hash_ipv4_segment([c, d])
    segment3 = hash_ipv4_segment([a, b, c, d])
    "#{segment1}.#{segment2}.#{segment3}.IP"
  end

  defp cloak_ip_address({a, b, c, d, e, f, g, h}) do
    prefix_hex = format_ipv6_segment(a) <> ":" <> format_ipv6_segment(b)
    hashed = hash_ipv6_segments([c, d, e, f, g, h])
    "#{prefix_hex}:#{hashed}.IP"
  end

  @spec cloak_short_hostname(String.t()) :: String.t()
  defp cloak_short_hostname(hostname) do
    segment1 = hash_data(hostname <> "-1")
    segment2 = hash_data(hostname <> "-2")
    segment3 = hash_data(hostname <> "-3")
    "#{segment1}.#{segment2}.#{segment3}.IP"
  end

  @spec hash_hostname_segments([String.t()]) :: String.t()
  defp hash_hostname_segments(segments) do
    data = Enum.join(segments, ".")
    hash_data(data)
  end

  @spec hash_ipv4_segment([integer()]) :: String.t()
  defp hash_ipv4_segment(octets) do
    data = Enum.map_join(octets, ".", &Integer.to_string/1)
    hash_data(data)
  end

  @spec hash_ipv6_segments([integer()]) :: String.t()
  defp hash_ipv6_segments(segments) do
    data = Enum.map_join(segments, ":", fn seg -> Integer.to_string(seg, 16) end)
    hash1 = hash_data(data <> "-1")
    hash2 = hash_data(data <> "-2")
    "#{hash1}:#{hash2}"
  end

  @spec hash_data(String.t()) :: String.t()
  defp hash_data(data) do
    keys = get_cloak_keys()
    secret_key = List.first(keys) || ""

    :crypto.mac(:hmac, :sha256, secret_key, data)
    |> Base.encode16()
    |> String.slice(0, 8)
  end

  @spec format_ipv6_segment(integer()) :: String.t()
  defp format_ipv6_segment(segment) do
    Integer.to_string(segment, 16)
    |> String.downcase()
  end

  @spec get_cloak_keys() :: [String.t()]
  defp get_cloak_keys do
    Application.get_env(:elixircd, :cloaking)[:cloak_keys]
  end
end
