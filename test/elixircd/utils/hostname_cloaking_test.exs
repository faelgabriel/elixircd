defmodule ElixIRCd.Utils.HostnameCloakingTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Utils.HostnameCloaking

  setup do
    original_config = Application.get_env(:elixircd, :cloaking, [])

    Application.put_env(:elixircd, :cloaking,
      cloak_keys: [
        "TestKey1MinimumThirtyCharactersLong123",
        "TestKey2MinimumThirtyCharactersLong456",
        "TestKey3MinimumThirtyCharactersLong789"
      ],
      cloak_prefix: "test",
      cloak_domain_parts: 2
    )

    on_exit(fn ->
      Application.put_env(:elixircd, :cloaking, original_config)
    end)

    :ok
  end

  describe "cloak/2" do
    test "cloaks IPv4 address when no hostname is provided" do
      result = HostnameCloaking.cloak({192, 168, 1, 100}, nil)
      assert String.ends_with?(result, ".IP")
      assert length(String.split(result, ".")) == 4
    end

    test "cloaks hostname when provided" do
      result = HostnameCloaking.cloak({192, 168, 1, 100}, "user.cable.example.com")
      assert String.starts_with?(result, "test-")
      assert String.ends_with?(result, ".example.com")
      refute String.ends_with?(result, ".IP")
    end

    test "cloaks IPv6 address when no hostname is provided" do
      result = HostnameCloaking.cloak({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, nil)
      assert String.ends_with?(result, ".IP")
      assert String.contains?(result, "2001:db8:")
    end

    test "returns same cloak for same input (deterministic)" do
      ip = {192, 168, 1, 100}
      hostname = "user.cable.example.com"

      result1 = HostnameCloaking.cloak(ip, hostname)
      result2 = HostnameCloaking.cloak(ip, hostname)

      assert result1 == result2
    end

    test "returns different cloak for different hostnames" do
      ip = {192, 168, 1, 100}
      hostname1 = "user1.cable.example.com"
      hostname2 = "user2.cable.example.com"

      result1 = HostnameCloaking.cloak(ip, hostname1)
      result2 = HostnameCloaking.cloak(ip, hostname2)

      refute result1 == result2
    end
  end

  describe "cloak/2 with resolved hostname" do
    test "masks first part of hostname with 3+ parts" do
      result = HostnameCloaking.cloak({192, 168, 1, 100}, "user.cable.example.com")
      assert String.starts_with?(result, "test-")
      assert String.ends_with?(result, ".example.com")
      refute String.contains?(result, "user")
      refute String.contains?(result, "cable")
    end

    test "masks first parts of hostname with 4+ parts" do
      result = HostnameCloaking.cloak({192, 168, 1, 100}, "user.host.cable.example.com")
      assert String.starts_with?(result, "test-")
      assert String.ends_with?(result, ".example.com")
      refute String.contains?(result, "user")
      refute String.contains?(result, "host")
      refute String.contains?(result, "cable")
    end

    test "uses IP-style cloaking for short hostname" do
      result = HostnameCloaking.cloak({192, 168, 1, 100}, "example.com")
      assert String.ends_with?(result, ".IP")
    end

    test "uses IP-style cloaking for single-part hostname" do
      result = HostnameCloaking.cloak({192, 168, 1, 100}, "localhost")
      assert String.ends_with?(result, ".IP")
    end

    test "is deterministic for same hostname" do
      hostname = "user.cable.example.com"
      result1 = HostnameCloaking.cloak({192, 168, 1, 100}, hostname)
      result2 = HostnameCloaking.cloak({192, 168, 1, 100}, hostname)
      assert result1 == result2
    end

    test "uses IP cloaking when hostname equals formatted IP" do
      result = HostnameCloaking.cloak({192, 168, 1, 100}, "192.168.1.100")
      assert String.ends_with?(result, ".IP")
    end

    test "uses hostname cloaking when hostname differs from formatted IP" do
      result = HostnameCloaking.cloak({192, 168, 1, 100}, "user.example.com")
      refute String.ends_with?(result, ".IP")
    end
  end

  describe "cloak/2 with IP address" do
    test "cloaks IPv4 address when hostname is nil" do
      result = HostnameCloaking.cloak({192, 168, 1, 100}, nil)
      assert String.ends_with?(result, ".IP")
      parts = String.split(result, ".")
      assert length(parts) == 4
      assert Enum.all?(Enum.take(parts, 3), &Regex.match?(~r/^[0-9A-F]{8}$/, &1))
    end

    test "cloaks IPv6 address when hostname is nil" do
      result = HostnameCloaking.cloak({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, nil)
      assert String.ends_with?(result, ".IP")
      assert String.starts_with?(result, "2001:")
    end

    test "IPv4 cloaking is deterministic" do
      ip = {192, 168, 1, 100}
      result1 = HostnameCloaking.cloak(ip, nil)
      result2 = HostnameCloaking.cloak(ip, nil)
      assert result1 == result2
    end

    test "IPv6 cloaking is deterministic" do
      ip = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
      result1 = HostnameCloaking.cloak(ip, nil)
      result2 = HostnameCloaking.cloak(ip, nil)
      assert result1 == result2
    end

    test "different IPv4 addresses produce different cloaks" do
      ip1 = {192, 168, 1, 100}
      ip2 = {192, 168, 1, 101}
      result1 = HostnameCloaking.cloak(ip1, nil)
      result2 = HostnameCloaking.cloak(ip2, nil)
      refute result1 == result2
    end

    test "different IPv6 addresses produce different cloaks" do
      ip1 = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
      ip2 = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 2}
      result1 = HostnameCloaking.cloak(ip1, nil)
      result2 = HostnameCloaking.cloak(ip2, nil)
      refute result1 == result2
    end
  end

  describe "cloak consistency with different keys" do
    test "different keys produce different cloaks for same input" do
      ip = {192, 168, 1, 100}
      hostname = "user.cable.example.com"

      result1 = HostnameCloaking.cloak(ip, hostname)

      Application.put_env(:elixircd, :cloaking,
        cloak_keys: [
          "DifferentKey1MinimumThirtyCharacters1",
          "DifferentKey2MinimumThirtyCharacters2",
          "DifferentKey3MinimumThirtyCharacters3"
        ],
        cloak_prefix: "test",
        cloak_domain_parts: 2
      )

      result2 = HostnameCloaking.cloak(ip, hostname)

      refute result1 == result2
    end
  end

  describe "edge cases" do
    test "handles hostname that looks like IP but is not the actual IP" do
      result = HostnameCloaking.cloak({192, 168, 1, 100}, "192.168.1.1")
      assert String.contains?(result, "test-")
    end

    test "handles hostname with only numbers and dots" do
      result = HostnameCloaking.cloak({192, 168, 1, 100}, "123.456.789")
      assert String.contains?(result, "test-")
    end

    test "handles very long hostname" do
      long_hostname = "very.long.subdomain.chain.with.many.parts.example.com"
      result = HostnameCloaking.cloak({192, 168, 1, 100}, long_hostname)
      assert String.starts_with?(result, "test-")
      assert String.ends_with?(result, ".example.com")
    end

    test "uses IP cloaking for IPv6 when hostname matches formatted IP" do
      ip = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
      formatted = "2001:db8::1"
      result = HostnameCloaking.cloak(ip, formatted)
      assert String.ends_with?(result, ".IP")
    end
  end
end
