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
        refill_rate: 2.0,
        capacity: 3,
        cost: 1,
        window_ms: 60_000,
        block_threshold: 2,
        block_ms: 60_000
      ],
      exceptions: [
        ips: ["127.0.0.1", "::1"],
        cidrs: ["10.0.0.0/8", "192.168.0.0/24"]
      ]
    ],
    message: [
      throttle: [
        refill_rate: 2.0,
        capacity: 5,
        cost: 1,
        window_ms: 60_000,
        disconnect_threshold: 5
      ],
      command_throttle: %{
        "JOIN" => [refill_rate: 1.0, capacity: 3, cost: 1, window_ms: 10_000, disconnect_threshold: 2],
        "PING" => [refill_rate: 2.0, capacity: 10, cost: 0],
        "NICK" => [refill_rate: 0.5, capacity: 5, cost: 5, disconnect_threshold: 5],
        "WHO" => [refill_rate: 1.0, capacity: 2, cost: 1],
        "WHOIS" => [refill_rate: 1.0, capacity: 2, cost: 1]
      },
      exceptions: [
        nicknames: ["Admin", "ServiceBot"],
        masks: ["*!*@localhost", "*!*staff@*.example.org"],
        umodes: ["o", "a"]
      ]
    ]
  ]

  setup do
    original_config = Application.get_env(:elixircd, :rate_limiter)
    Application.put_env(:elixircd, :rate_limiter, Keyword.merge(original_config, @test_config))

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

        # Token bucket allows burst up to capacity (3), then throttles
        assert :ok = RateLimiter.check_connection(test_ip)
        assert :ok = RateLimiter.check_connection(test_ip)
        assert :ok = RateLimiter.check_connection(test_ip)

        # Fourth connection should be throttled with proper retry time
        result = RateLimiter.check_connection(test_ip)
        assert {:error, :throttled, retry_ms} = result
        assert is_integer(retry_ms) and retry_ms > 0
        # With refill_rate 2.0 tokens/sec and cost 1, should be around 500ms
        assert retry_ms <= 1000
      end)
    end

    test "handles violations with proper escalation" do
      Memento.transaction!(fn ->
        test_ip = {192, 168, 1, 102}

        # Exhaust capacity first
        assert :ok = RateLimiter.check_connection(test_ip)
        assert :ok = RateLimiter.check_connection(test_ip)
        assert :ok = RateLimiter.check_connection(test_ip)

        # Get violations (configured block_threshold is 2)
        assert {:error, :throttled, _} = RateLimiter.check_connection(test_ip)

        # After repeated violations, should escalate to throttled_exceeded
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
      {:ok, user: insert(:user)}
    end

    test "allows message when under rate limit", %{user: user} do
      # Token bucket allows burst up to capacity (5)
      assert :ok = RateLimiter.check_message(user, "PRIVMSG #test :Hello")
      assert :ok = RateLimiter.check_message(user, "PRIVMSG #test :Hello again")
      assert :ok = RateLimiter.check_message(user, "PRIVMSG #test :Hello third")
    end

    test "throttles message when token bucket is exhausted", %{user: user} do
      # Exhaust the capacity (5 tokens)
      for i <- 1..5 do
        assert :ok = RateLimiter.check_message(user, "PRIVMSG #test :Message #{i}")
      end

      # 6th message should be throttled with proper retry time
      result = RateLimiter.check_message(user, "PRIVMSG #test :Too many messages")
      assert {:error, :throttled, retry_ms} = result
      assert is_integer(retry_ms) and retry_ms > 0
      # With refill_rate 2.0 tokens/sec and cost 1, should be around 500ms
      assert retry_ms <= 1000
    end

    test "disconnects user after repeated violations", %{user: user} do
      # First exhaust capacity to start getting violations
      for i <- 1..5 do
        assert :ok = RateLimiter.check_message(user, "PRIVMSG #test :Message #{i}")
      end

      # Get violations (default disconnect_threshold is 5)
      for _i <- 1..4 do
        assert {:error, :throttled, _} = RateLimiter.check_message(user, "PRIVMSG #test :Violation")
      end

      # 5th violation should trigger disconnect
      assert {:error, :throttled_exceeded} = RateLimiter.check_message(user, "PRIVMSG #test :Final violation")
    end

    test "applies command-specific throttling for JOIN", %{user: user} do
      # JOIN has: refill_rate: 1.0, capacity: 3
      assert :ok = RateLimiter.check_message(user, "JOIN #channel1")
      assert :ok = RateLimiter.check_message(user, "JOIN #channel2")
      assert :ok = RateLimiter.check_message(user, "JOIN #channel3")

      # 4th JOIN should be throttled
      result = RateLimiter.check_message(user, "JOIN #channel4")
      assert {:error, :throttled, retry_ms} = result
      # With refill_rate 1.0 tokens/sec and cost 1, should be around 1000ms
      assert retry_ms <= 1500
    end

    test "applies command-specific throttling for PING with zero cost", %{user: user} do
      # PING has cost: 0, so it should never be throttled by rate
      for i <- 1..20 do
        assert :ok = RateLimiter.check_message(user, "PING :server#{i}")
      end
    end

    test "applies command-specific throttling for NICK with high cost", %{user: user} do
      # NICK has: refill_rate: 0.5, capacity: 5, cost: 5
      # First NICK should work (uses all 5 initial tokens)
      assert :ok = RateLimiter.check_message(user, "NICK newnick1")

      # Second NICK should be throttled as bucket is empty
      result = RateLimiter.check_message(user, "NICK newnick2")
      assert {:error, :throttled, retry_ms} = result
      # With refill_rate 0.5 tokens/sec and cost 5, should be 10000ms
      assert retry_ms >= 9_000 and retry_ms <= 11_000
    end

    test "handles different commands with separate rate limits", %{user: user} do
      # Regular PRIVMSG should work fine
      assert :ok = RateLimiter.check_message(user, "PRIVMSG #test :Hello")

      # WHO has separate limits: refill_rate: 1.0, capacity: 2
      assert :ok = RateLimiter.check_message(user, "WHO #channel")
      assert :ok = RateLimiter.check_message(user, "WHO #channel2")

      # Third WHO should be throttled due to capacity
      result = RateLimiter.check_message(user, "WHO #channel3")
      assert {:error, :throttled, _} = result

      # But PRIVMSG should still work (separate buckets)
      assert :ok = RateLimiter.check_message(user, "PRIVMSG #test :Still works")
    end

    test "handles generic messages", %{user: user} do
      assert :ok = RateLimiter.check_message(user, "")
      assert :ok = RateLimiter.check_message(user, "ANYTHING")
      assert :ok = RateLimiter.check_message(user, "ANYTHING ANYTHING")
    end

    test "allows messages from users with excepted nicknames" do
      # Create user with an identified nickname that matches the exception list
      user_with_excepted_nick =
        insert(:user, %{
          registered: true,
          hostname: "host.example.com",
          ident: "~testuser",
          identified_as: "Admin"
        })

      # Verify the user is excepted from rate limiting
      assert :ok = RateLimiter.check_message(user_with_excepted_nick, "PRIVMSG #test :Message 1")

      # Even after exceeding normal capacity, the user should still be allowed
      for i <- 1..20 do
        assert :ok = RateLimiter.check_message(user_with_excepted_nick, "PRIVMSG #test :Message #{i}")
      end

      # Case insensitive nickname matching should work
      user_with_case_diff_nick =
        insert(:user, %{
          registered: true,
          hostname: "host.example.com",
          ident: "~testuser",
          identified_as: "admin"
        })

      assert :ok = RateLimiter.check_message(user_with_case_diff_nick, "PRIVMSG #test :Message from admin")
    end

    test "allows messages from users with excepted user modes" do
      # Create user with modes that match the exception list
      user_with_excepted_mode =
        insert(:user, %{
          registered: true,
          hostname: "host.example.com",
          ident: "~testuser",
          modes: ["o", "v"]
        })

      # Verify the user is excepted from rate limiting
      assert :ok = RateLimiter.check_message(user_with_excepted_mode, "PRIVMSG #test :Message 1")

      # Even after exceeding normal capacity, the user should still be allowed
      for i <- 1..20 do
        assert :ok = RateLimiter.check_message(user_with_excepted_mode, "PRIVMSG #test :Message #{i}")
      end

      # Check another excepted mode
      user_with_another_mode =
        insert(:user, %{
          registered: true,
          hostname: "host.example.com",
          ident: "~testuser",
          modes: ["a", "v"]
        })

      assert :ok = RateLimiter.check_message(user_with_another_mode, "PRIVMSG #test :Message from admin")

      # Verify that non-excepted modes don't get the exception
      user_without_excepted_mode =
        insert(:user, %{
          registered: true,
          hostname: "host.example.com",
          ident: "~testuser",
          modes: ["v", "i"]
        })

      # Exhaust the capacity
      for i <- 1..5 do
        assert :ok = RateLimiter.check_message(user_without_excepted_mode, "PRIVMSG #test :Message #{i}")
      end

      # 6th message should be throttled
      result = RateLimiter.check_message(user_without_excepted_mode, "PRIVMSG #test :Too many messages")
      assert {:error, :throttled, retry_ms} = result
      assert is_integer(retry_ms) and retry_ms > 0
    end

    test "allows messages from users with matching host masks" do
      # Create user to match the localhost mask
      user_with_localhost =
        insert(:user, %{
          registered: true,
          ip_address: {127, 0, 0, 1},
          hostname: "localhost",
          ident: "~anyone",
          nick: "localuser"
        })

      # Verify the user is excepted from rate limiting
      assert :ok = RateLimiter.check_message(user_with_localhost, "PRIVMSG #test :Message 1")

      # Even after exceeding normal capacity, the user should still be allowed
      for i <- 1..20 do
        assert :ok = RateLimiter.check_message(user_with_localhost, "PRIVMSG #test :Message #{i}")
      end

      # Create user to match the staff mask
      user_with_staff_mask =
        insert(:user, %{
          registered: true,
          hostname: "irc.example.org",
          ident: "~staff",
          nick: "staffmember"
        })

      # Verify the user is excepted from rate limiting
      assert :ok = RateLimiter.check_message(user_with_staff_mask, "PRIVMSG #test :Message 1")

      # Even after exceeding normal capacity, the user should still be allowed
      for i <- 1..20 do
        assert :ok = RateLimiter.check_message(user_with_staff_mask, "PRIVMSG #test :Message #{i}")
      end
    end
  end
end
