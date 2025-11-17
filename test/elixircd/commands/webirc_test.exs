defmodule ElixIRCd.Commands.WebircTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase

  alias ElixIRCd.Commands.Webirc
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users

  import ElixIRCd.Factory
  import ExUnit.CaptureLog

  describe "handle/2 - WEBIRC disabled" do
    test "rejects WEBIRC when disabled in config" do
      original_config = Application.get_env(:elixircd, :webirc)
      on_exit(fn -> Application.put_env(:elixircd, :webirc, original_config) end)

      Application.put_env(:elixircd, :webirc, enabled: false)

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "WEBIRC", params: ["pass", "gateway", "host", "1.2.3.4"]}

        assert {:quit, "WEBIRC is not enabled on this server"} = Webirc.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test ERROR :WEBIRC is not enabled on this server\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - registration state validation" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)
      on_exit(fn -> Application.put_env(:elixircd, :webirc, original_config) end)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["127.0.0.1"],
            password: "test_password",
            name: "Test Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      :ok
    end

    test "rejects WEBIRC when user already registered" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: true, ip_address: {127, 0, 0, 1})
        message = %Message{command: "WEBIRC", params: ["test_password", "gateway", "host", "1.2.3.4"]}

        assert {:quit, "WEBIRC must be sent before registration"} = Webirc.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test ERROR :WEBIRC must be sent before registration\r\n"}
        ])
      end)
    end

    test "rejects WEBIRC when already used" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, webirc_used: true, ip_address: {127, 0, 0, 1})
        message = %Message{command: "WEBIRC", params: ["test_password", "gateway", "host", "1.2.3.4"]}

        assert {:quit, "WEBIRC can only be used once per connection"} = Webirc.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test ERROR :WEBIRC can only be used once per connection\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - parameter validation" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)
      on_exit(fn -> Application.put_env(:elixircd, :webirc, original_config) end)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["127.0.0.1"],
            password: "test_password",
            name: "Test Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      :ok
    end

    test "rejects WEBIRC with insufficient parameters - 0 params" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})
        message = %Message{command: "WEBIRC", params: []}

        assert {:quit, "WEBIRC requires at least 4 parameters"} = Webirc.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test ERROR :WEBIRC requires at least 4 parameters\r\n"}
        ])
      end)
    end

    test "rejects WEBIRC with insufficient parameters - 3 params" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})
        message = %Message{command: "WEBIRC", params: ["pass", "gateway", "host"]}

        assert {:quit, "WEBIRC requires at least 4 parameters"} = Webirc.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test ERROR :WEBIRC requires at least 4 parameters\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - gateway authentication" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)
      on_exit(fn -> Application.put_env(:elixircd, :webirc, original_config) end)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["192.168.1.100"],
            password: "correct_password",
            name: "Authorized Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      :ok
    end

    test "rejects WEBIRC from unauthorized IP" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {10, 0, 0, 1})
            message = %Message{command: "WEBIRC", params: ["correct_password", "gateway", "host", "1.2.3.4"]}

            assert {:quit, "Access denied - Unauthorized WebIRC gateway"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Access denied - Unauthorized WebIRC gateway\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 10.0.0.1 - unauthorized gateway"
    end

    test "rejects WEBIRC with invalid password" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {192, 168, 1, 100})
            message = %Message{command: "WEBIRC", params: ["wrong_password", "gateway", "host", "1.2.3.4"]}

            assert {:quit, "Access denied - Invalid WebIRC password"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Access denied - Invalid WebIRC password\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 192.168.1.100 - invalid password"
    end
  end

  describe "handle/2 - IP validation" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)
      on_exit(fn -> Application.put_env(:elixircd, :webirc, original_config) end)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["127.0.0.1"],
            password: "test_password",
            name: "Test Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      :ok
    end

    test "rejects WEBIRC with invalid IP format" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})
            message = %Message{command: "WEBIRC", params: ["test_password", "gateway", "host", "invalid.ip"]}

            assert {:quit, "Invalid IP address format"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Invalid IP address format\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 127.0.0.1 - invalid IP format"
    end

    test "rejects IPv6 when not allowed" do
      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["127.0.0.1"],
            password: "test_password",
            name: "Test Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: false
      )

      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})
            message = %Message{command: "WEBIRC", params: ["test_password", "gateway", "host", "2001:db8::1"]}

            assert {:quit, "IPv6 addresses are not allowed"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :IPv6 addresses are not allowed\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 127.0.0.1 - IPv6 not allowed"
    end
  end

  describe "handle/2 - successful WEBIRC" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)
      on_exit(fn -> Application.put_env(:elixircd, :webirc, original_config) end)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["127.0.0.1"],
            password: "test_password",
            name: "Test Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      :ok
    end

    test "accepts valid WEBIRC with IPv4" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})
        message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "user.host.com", "1.2.3.4"]}

        assert :ok = Webirc.handle(user, message)

        # No messages should be sent (silent success)
        assert_sent_messages([])

        # Verify user was updated correctly
        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.ip_address == {1, 2, 3, 4}
        assert updated_user.hostname == "user.host.com"
        assert updated_user.webirc_gateway == "TestGW"
        assert updated_user.webirc_hostname == "user.host.com"
        assert updated_user.webirc_ip == "1.2.3.4"
        assert updated_user.webirc_used == true
        assert updated_user.webirc_secure == false
      end)
    end

    test "accepts valid WEBIRC with IPv6" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})

        message =
          %Message{command: "WEBIRC", params: ["test_password", "TestGW", "user.host.com", "2001:db8::1"]}

        assert :ok = Webirc.handle(user, message)

        assert_sent_messages([])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.ip_address == {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
        assert updated_user.hostname == "user.host.com"
        assert updated_user.webirc_used == true
      end)
    end

    test "accepts valid WEBIRC with IPv6 starting with colon" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})

        message =
          %Message{command: "WEBIRC", params: ["test_password", "TestGW", "user.host.com", ":2001:db8::1"]}

        assert :ok = Webirc.handle(user, message)

        assert_sent_messages([])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        # Should handle leading colon properly
        assert updated_user.ip_address == {0, 0x2001, 0x0DB8, 0, 0, 0, 0, 1}
        assert updated_user.webirc_used == true
      end)
    end

    test "accepts WEBIRC with secure option" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})

        message =
          %Message{command: "WEBIRC", params: ["test_password", "TestGW", "user.host.com", "1.2.3.4", "secure"]}

        assert :ok = Webirc.handle(user, message)

        assert_sent_messages([])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.webirc_secure == true
      end)
    end

    test "accepts WEBIRC with multiple options" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})

        message =
          %Message{
            command: "WEBIRC",
            params: ["test_password", "TestGW", "user.host.com", "1.2.3.4", "secure remote-port=12345"]
          }

        assert :ok = Webirc.handle(user, message)

        assert_sent_messages([])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.webirc_secure == true
        assert updated_user.ip_address == {1, 2, 3, 4}
      end)
    end
  end

  describe "handle/2 - CIDR matching" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)
      on_exit(fn -> Application.put_env(:elixircd, :webirc, original_config) end)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["192.168.1.0/24", "10.0.0.0/8"],
            password: "test_password",
            name: "CIDR Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      :ok
    end

    test "accepts WEBIRC from IP in CIDR range /24" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, ip_address: {192, 168, 1, 50})
        message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "host", "1.2.3.4"]}

        assert :ok = Webirc.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "accepts WEBIRC from IP in CIDR range /8" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, ip_address: {10, 5, 10, 15})
        message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "host", "1.2.3.4"]}

        assert :ok = Webirc.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "rejects WEBIRC from IP outside CIDR range" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {192, 168, 2, 1})
            message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "host", "1.2.3.4"]}

            assert {:quit, "Access denied - Unauthorized WebIRC gateway"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Access denied - Unauthorized WebIRC gateway\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 192.168.2.1 - unauthorized gateway"
    end
  end

  describe "handle/2 - hostname validation" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)
      on_exit(fn -> Application.put_env(:elixircd, :webirc, original_config) end)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["127.0.0.1"],
            password: "test_password",
            name: "Test Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      :ok
    end

    test "accepts hostname when verify_hostname is false" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})
        message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "any.hostname.com", "1.2.3.4"]}

        assert :ok = Webirc.handle(user, message)

        assert_sent_messages([])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.hostname == "any.hostname.com"
      end)
    end

    test "accepts IP as hostname" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})
        message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "1.2.3.4", "1.2.3.4"]}

        assert :ok = Webirc.handle(user, message)

        assert_sent_messages([])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.hostname == "1.2.3.4"
      end)
    end
  end

  describe "handle/2 - logging" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)
      on_exit(fn -> Application.put_env(:elixircd, :webirc, original_config) end)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["127.0.0.1"],
            password: "test_password",
            name: "Test Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      :ok
    end
  end

  describe "handle/2 - hostname validation edge cases" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)
      on_exit(fn -> Application.put_env(:elixircd, :webirc, original_config) end)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["127.0.0.1"],
            password: "test_password",
            name: "Test Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      :ok
    end

    test "rejects empty hostname" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})
            message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "", "1.2.3.4"]}

            assert {:quit, "Invalid hostname"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Invalid hostname\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 127.0.0.1 - invalid hostname"
    end

    test "rejects whitespace-only hostname" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})
            message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "   ", "1.2.3.4"]}

            assert {:quit, "Invalid hostname"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Invalid hostname\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 127.0.0.1 - invalid hostname"
    end
  end

  describe "handle/2 - hostname verification enabled" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)
      on_exit(fn -> Application.put_env(:elixircd, :webirc, original_config) end)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["127.0.0.1"],
            password: "test_password",
            name: "Test Gateway"
          }
        ],
        verify_hostname: true,
        allow_ipv6: true
      )

      :ok
    end

    test "accepts hostname when DNS resolution succeeds and IP matches" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})
        # Using localhost which should resolve to 127.0.0.1
        message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "localhost", "127.0.0.1"]}

        assert :ok = Webirc.handle(user, message)

        assert_sent_messages([])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.hostname == "localhost"
      end)
    end

    test "rejects hostname when DNS resolution succeeds but IP does not match" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})
            message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "localhost", "1.2.3.4"]}

            assert {:quit, "Invalid hostname"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Invalid hostname\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 127.0.0.1 - invalid hostname"
    end

    test "accepts hostname when DNS resolution fails" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})

        message =
          %Message{
            command: "WEBIRC",
            params: ["test_password", "TestGW", "non-existent-domain-xyz123.invalid", "1.2.3.4"]
          }

        assert :ok = Webirc.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end

  describe "handle/2 - parse_options edge cases" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)
      on_exit(fn -> Application.put_env(:elixircd, :webirc, original_config) end)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["127.0.0.1"],
            password: "test_password",
            name: "Test Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      :ok
    end

    test "handles WEBIRC with options containing escaped characters" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})

        message =
          %Message{
            command: "WEBIRC",
            params: [
              "test_password",
              "TestGW",
              "user.host.com",
              "1.2.3.4",
              "key=value\\:with\\:semicolons key2=value\\swith\\sspaces"
            ]
          }

        assert :ok = Webirc.handle(user, message)

        assert_sent_messages([])

        {:ok, updated_user} = Users.get_by_pid(user.pid)
        assert updated_user.ip_address == {1, 2, 3, 4}
      end)
    end

    test "handles WEBIRC with options containing all escape sequences" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})

        message =
          %Message{
            command: "WEBIRC",
            params: [
              "test_password",
              "TestGW",
              "user.host.com",
              "1.2.3.4",
              "test=value\\\\backslash\\rcarriage\\nreturn"
            ]
          }

        assert :ok = Webirc.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end

  describe "handle/2 - IPv6 CIDR matching" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)
      on_exit(fn -> Application.put_env(:elixircd, :webirc, original_config) end)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["2001:db8::/32"],
            password: "test_password",
            name: "IPv6 Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      on_exit(fn ->
        Application.put_env(:elixircd, :webirc, original_config)
      end)

      :ok
    end

    test "accepts WEBIRC from IPv6 in CIDR range" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, ip_address: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
        message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "host", "1.2.3.4"]}

        assert :ok = Webirc.handle(user, message)

        assert_sent_messages([])
      end)
    end

    test "rejects WEBIRC from IPv6 outside CIDR range" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {0x2001, 0x0DC8, 0, 0, 0, 0, 0, 1})
            message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "host", "1.2.3.4"]}

            assert {:quit, "Access denied - Unauthorized WebIRC gateway"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Access denied - Unauthorized WebIRC gateway\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 2001:DC8::1 - unauthorized gateway"
    end
  end

  describe "handle/2 - CIDR edge cases" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)
      on_exit(fn -> Application.put_env(:elixircd, :webirc, original_config) end)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["192.168.1.0/invalid", "malformed"],
            password: "test_password",
            name: "Test Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      :ok
    end

    test "rejects WEBIRC when gateway IP list contains invalid CIDR notation" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {192, 168, 1, 1})
            message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "host", "1.2.3.4"]}

            assert {:quit, "Access denied - Unauthorized WebIRC gateway"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Access denied - Unauthorized WebIRC gateway\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 192.168.1.1 - unauthorized gateway"
    end

    test "rejects WEBIRC when gateway IP list contains malformed IP" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {192, 168, 1, 1})
            message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "host", "1.2.3.4"]}

            assert {:quit, "Access denied - Unauthorized WebIRC gateway"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Access denied - Unauthorized WebIRC gateway\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 192.168.1.1 - unauthorized gateway"
    end
  end

  describe "handle/2 - invalid CIDR formats" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["192.168.1.0/abc", "10.0.0.0/"],
            password: "test_password",
            name: "Invalid CIDR Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      on_exit(fn ->
        Application.put_env(:elixircd, :webirc, original_config)
      end)

      :ok
    end

    test "rejects WEBIRC when CIDR has non-numeric prefix length" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {192, 168, 1, 50})
            message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "host", "1.2.3.4"]}

            assert {:quit, "Access denied - Unauthorized WebIRC gateway"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Access denied - Unauthorized WebIRC gateway\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 192.168.1.50 - unauthorized gateway"
    end

    test "rejects WEBIRC when CIDR is missing prefix length" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {10, 0, 0, 1})
            message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "host", "1.2.3.4"]}

            assert {:quit, "Access denied - Unauthorized WebIRC gateway"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Access denied - Unauthorized WebIRC gateway\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 10.0.0.1 - unauthorized gateway"
    end
  end

  describe "handle/2 - mismatched IP types in CIDR" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["127.0.0.1"],
            password: "test_password",
            name: "Test Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      on_exit(fn ->
        Application.put_env(:elixircd, :webirc, original_config)
      end)

      :ok
    end

    test "handles WEBIRC with valid credentials" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})
        message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "host.com", "1.2.3.4"]}

        assert :ok = Webirc.handle(user, message)

        assert_sent_messages([])
      end)
    end
  end

  describe "handle/2 - extreme edge cases for full coverage" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["192.168.1.0/999"],
            password: "test_password",
            name: "Invalid Prefix Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      on_exit(fn ->
        Application.put_env(:elixircd, :webirc, original_config)
      end)

      :ok
    end

    test "handles CIDR with prefix length exceeding maximum" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {192, 168, 1, 1})
            message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "host", "1.2.3.4"]}

            # Should fail authorization because the CIDR is invalid
            assert {:quit, "Access denied - Unauthorized WebIRC gateway"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Access denied - Unauthorized WebIRC gateway\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 192.168.1.1 - unauthorized gateway"
    end
  end

  describe "handle/2 - IPv4/IPv6 CIDR mismatch" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["192.168.1.0/24"],
            password: "test_password",
            name: "IPv4 Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      on_exit(fn ->
        Application.put_env(:elixircd, :webirc, original_config)
      end)

      :ok
    end

    test "rejects IPv6 address when gateway expects IPv4 CIDR" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            # User connecting from IPv6 but gateway is configured for IPv4
            user = insert(:user, registered: false, ip_address: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
            message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "host", "1.2.3.4"]}

            assert {:quit, "Access denied - Unauthorized WebIRC gateway"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Access denied - Unauthorized WebIRC gateway\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 2001:DB8::1 - unauthorized gateway"
    end
  end

  describe "handle/2 - malformed CIDR causing rescue" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)

      # This setup tries to create conditions that might trigger rescue clauses
      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["192.168.1.0/24/extra"],
            password: "test_password",
            name: "Malformed CIDR Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      on_exit(fn ->
        Application.put_env(:elixircd, :webirc, original_config)
      end)

      :ok
    end

    test "handles CIDR with extra slashes gracefully" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {192, 168, 1, 1})
            message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "host", "1.2.3.4"]}

            # The malformed CIDR should not match, resulting in unauthorized
            assert {:quit, "Access denied - Unauthorized WebIRC gateway"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Access denied - Unauthorized WebIRC gateway\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 192.168.1.1 - unauthorized gateway"
    end
  end

  describe "handle/2 - CIDR edge cases triggering rescue clauses" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)

      # Configure gateway with potentially problematic CIDR that might cause exceptions
      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            # CIDR with very large prefix that might cause bitstring errors
            ips: ["192.168.1.0/200"],
            password: "test_password",
            name: "Large Prefix Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      on_exit(fn ->
        Application.put_env(:elixircd, :webirc, original_config)
      end)

      :ok
    end

    test "handles CIDR with excessively large prefix length" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {192, 168, 1, 1})
            message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "host", "1.2.3.4"]}

            # Should result in unauthorized due to invalid CIDR
            assert {:quit, "Access denied - Unauthorized WebIRC gateway"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Access denied - Unauthorized WebIRC gateway\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 192.168.1.1 - unauthorized gateway"
    end
  end

  describe "handle/2 - empty gateway list edge case" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: [],
            password: "test_password",
            name: "Empty IPs Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      on_exit(fn ->
        Application.put_env(:elixircd, :webirc, original_config)
      end)

      :ok
    end

    test "rejects WEBIRC when gateway has empty IPs list" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {127, 0, 0, 1})
            message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "host", "1.2.3.4"]}

            assert {:quit, "Access denied - Unauthorized WebIRC gateway"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Access denied - Unauthorized WebIRC gateway\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 127.0.0.1 - unauthorized gateway"
    end
  end

  describe "handle/2 - truly no matching gateway" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)
      on_exit(fn -> Application.put_env(:elixircd, :webirc, original_config) end)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["127.0.0.1"],
            password: "password1",
            name: "Gateway 1"
          },
          %{
            ips: ["10.0.0.2"],
            password: "password2",
            name: "Gateway 2"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      :ok
    end

    test "rejects WEBIRC when no gateway matches connecting IP" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {192, 168, 1, 1})
            message = %Message{command: "WEBIRC", params: ["password1", "TestGW", "host", "1.2.3.4"]}

            assert {:quit, "Access denied - Unauthorized WebIRC gateway"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Access denied - Unauthorized WebIRC gateway\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 192.168.1.1 - unauthorized gateway"
    end
  end

  describe "handle/2 - explicit nil from find_gateway_config" do
    setup do
      original_config = Application.get_env(:elixircd, :webirc)

      Application.put_env(:elixircd, :webirc,
        enabled: true,
        gateways: [
          %{
            ips: ["not-an-ip-address"],
            password: "test_password",
            name: "Malformed IP Gateway"
          }
        ],
        verify_hostname: false,
        allow_ipv6: true
      )

      on_exit(fn ->
        Application.put_env(:elixircd, :webirc, original_config)
      end)

      :ok
    end

    test "covers nil branch in find_gateway_config when no gateway matches" do
      log =
        capture_log(fn ->
          Memento.transaction!(fn ->
            user = insert(:user, registered: false, ip_address: {192, 168, 1, 1})
            message = %Message{command: "WEBIRC", params: ["test_password", "TestGW", "host", "1.2.3.4"]}

            assert {:quit, "Access denied - Unauthorized WebIRC gateway"} = Webirc.handle(user, message)

            assert_sent_messages([
              {user.pid, ":irc.test ERROR :Access denied - Unauthorized WebIRC gateway\r\n"}
            ])
          end)
        end)

      assert log =~ "WEBIRC: Failed authentication from 192.168.1.1 - unauthorized gateway"
    end
  end
end
