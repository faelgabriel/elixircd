defmodule ElixIRCd.Server.RateLimiterTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Server.RateLimiter

  @test_config [
    connection: [
      max_connections_per_ip: 2,
      throttle: [
        refill_rate: 0.05,
        capacity: 3,
        cost: 1,
        window_ms: 60_000,
        block_threshold: 2,
        block_ms: 60_000
      ]
    ],
    message: [
      throttle: [
        refill_rate: 1.0,
        capacity: 10,
        cost: 1,
        window_ms: 60_000,
        disconnect_threshold: 5
      ],
      command_throttle: %{
        "JOIN" => [refill_rate: 0.3, capacity: 3, cost: 1, window_ms: 10_000, disconnect_threshold: 2],
        "PING" => [refill_rate: 2.0, capacity: 10, cost: 0],
        "NICK" => [refill_rate: 0.1, capacity: 1, cost: 3],
        "WHO" => [refill_rate: 0.2, capacity: 2, cost: 1],
        "WHOIS" => [refill_rate: 0.2, capacity: 2, cost: 1]
      },
      exceptions: [
        ips: ["127.0.0.1", "::1"],
        cidrs: ["10.0.0.0/8", "192.168.0.0/24"]
      ]
    ]
  ]

  setup do
    original_config = Application.get_env(:elixircd, :rate_limiter)
    Application.put_env(:elixircd, :rate_limiter, @test_config)

    on_exit(fn ->
      Application.put_env(:elixircd, :rate_limiter, original_config)
    end)

    :ok
  end

  describe "check_connection/1" do
    test "allows excepted IP addresses" do
      Memento.transaction!(fn ->
        assert :ok = RateLimiter.check_connection({127, 0, 0, 1})
        assert :ok = RateLimiter.check_connection({0, 0, 0, 0, 0, 0, 0, 1})
      end)
    end

    test "allows IPs in excepted CIDR ranges" do
      Memento.transaction!(fn ->
        assert :ok = RateLimiter.check_connection({10, 10, 10, 10})
        assert :ok = RateLimiter.check_connection({192, 168, 0, 100})
      end)
    end

    test "allows non-excepted IP when under rate limit and max connections" do
      Memento.transaction!(fn ->
        test_ip = {192, 168, 1, 100}

        assert :ok = RateLimiter.check_connection(test_ip)
      end)
    end

    test "throttles non-excepted IP when rate limit is exceeded" do
      Memento.transaction!(fn ->
        test_ip = {192, 168, 1, 101}

        # Exhaust the capacity (default is 3)
        assert :ok = RateLimiter.check_connection(test_ip)
        assert :ok = RateLimiter.check_connection(test_ip)
        assert :ok = RateLimiter.check_connection(test_ip)

        # Fourth connection should be throttled
        result = RateLimiter.check_connection(test_ip)
        assert {:error, :throttled, retry_ms} = result
        assert is_integer(retry_ms) and retry_ms > 0
      end)
    end

    test "blocks IP after repeated violations" do
      Memento.transaction!(fn ->
        test_ip = {192, 168, 1, 102}

        # First, exhaust capacity to trigger violations
        assert :ok = RateLimiter.check_connection(test_ip)
        assert :ok = RateLimiter.check_connection(test_ip)
        assert :ok = RateLimiter.check_connection(test_ip)

        # Get violations (default block_threshold is 2)
        # First violation
        assert {:error, :throttled, _} = RateLimiter.check_connection(test_ip)

        # Second violation should trigger block immediately
        assert {:error, :throttled_exceeded} = RateLimiter.check_connection(test_ip)

        # Subsequent attempts should also be blocked
        assert {:error, :throttled_exceeded} = RateLimiter.check_connection(test_ip)
      end)
    end

    test "rejects connections when max_connections_per_ip is reached" do
      Memento.transaction!(fn ->
        test_ip = {192, 168, 1, 103}

        insert(:user, %{ip_address: test_ip, port_connected: 1234})
        insert(:user, %{ip_address: test_ip, port_connected: 1235})

        assert {:error, :max_connections_exceeded} = RateLimiter.check_connection(test_ip)
      end)
    end
  end

  describe "check_message/2" do
    setup do
      {:ok, pid: spawn(fn -> :ok end)}
    end

    test "allows message when under rate limit", %{pid: pid} do
      # Default rate limit is generous (1.0 refill_rate, 10 capacity)
      assert :ok = RateLimiter.check_message(pid, "PRIVMSG #test :Hello")
      assert :ok = RateLimiter.check_message(pid, "PRIVMSG #test :Hello again")
    end

    test "throttles message when rate limit is exceeded", %{pid: pid} do
      # Exhaust the capacity quickly (default capacity is 10)
      for i <- 1..10 do
        assert :ok = RateLimiter.check_message(pid, "PRIVMSG #test :Message #{i}")
      end

      # 11th message should be throttled
      result = RateLimiter.check_message(pid, "PRIVMSG #test :Too many messages")
      assert {:error, :throttled, retry_ms} = result
      assert is_integer(retry_ms) and retry_ms > 0
    end

    test "disconnects user after repeated violations", %{pid: pid} do
      # First exhaust capacity to start getting violations
      for i <- 1..10 do
        assert :ok = RateLimiter.check_message(pid, "PRIVMSG #test :Message #{i}")
      end

      # Get violations (default disconnect_threshold is 5)
      for _i <- 1..4 do
        assert {:error, :throttled, _} = RateLimiter.check_message(pid, "PRIVMSG #test :Violation")
      end

      # 5th violation should trigger disconnect
      assert {:error, :throttled_exceeded} = RateLimiter.check_message(pid, "PRIVMSG #test :Final violation")
    end

    test "applies command-specific throttling for JOIN", %{pid: pid} do
      # JOIN has stricter limits: refill_rate: 0.3, capacity: 3
      assert :ok = RateLimiter.check_message(pid, "JOIN #channel1")
      assert :ok = RateLimiter.check_message(pid, "JOIN #channel2")
      assert :ok = RateLimiter.check_message(pid, "JOIN #channel3")

      # 4th JOIN should be throttled
      result = RateLimiter.check_message(pid, "JOIN #channel4")
      assert {:error, :throttled, _} = result
    end

    test "applies command-specific throttling for PING with zero cost", %{pid: pid} do
      # PING has cost: 0, so it should never be throttled by rate
      for i <- 1..20 do
        assert :ok = RateLimiter.check_message(pid, "PING :server#{i}")
      end
    end

    test "applies command-specific throttling for NICK", %{pid: pid} do
      # NICK has: refill_rate: 0.1, capacity: 1, cost: 3
      # So only 1 token, and costs 3 - should be throttled immediately
      result = RateLimiter.check_message(pid, "NICK newnick")
      assert {:error, :throttled, _} = result
    end

    test "handles different commands with separate rate limits", %{pid: pid} do
      # Regular PRIVMSG should work fine
      assert :ok = RateLimiter.check_message(pid, "PRIVMSG #test :Hello")

      # WHO has separate limits: refill_rate: 0.2, capacity: 2
      assert :ok = RateLimiter.check_message(pid, "WHO #channel")
      assert :ok = RateLimiter.check_message(pid, "WHO #channel2")

      # Third WHO should be throttled due to capacity
      result = RateLimiter.check_message(pid, "WHO #channel3")
      assert {:error, :throttled, _} = result

      # But PRIVMSG should still work (separate buckets)
      assert :ok = RateLimiter.check_message(pid, "PRIVMSG #test :Still works")
    end

    test "handles generic messages", %{pid: pid} do
      assert :ok = RateLimiter.check_message(pid, "")
      assert :ok = RateLimiter.check_message(pid, "ANYTHING")
      assert :ok = RateLimiter.check_message(pid, "ANYTHING ANYTHING")
    end
  end
end
