defmodule ElixIRCd.Commands.AuthenticateTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Authenticate
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.SaslSessions
  alias ElixIRCd.Repositories.Users

  setup do
    original_caps = Application.get_env(:elixircd, :capabilities)
    original_sasl = Application.get_env(:elixircd, :sasl)

    on_exit(fn ->
      Application.put_env(:elixircd, :capabilities, original_caps)
      Application.put_env(:elixircd, :sasl, original_sasl)
    end)

    Application.put_env(
      :elixircd,
      :capabilities,
      (original_caps || [])
      |> Keyword.put(:sasl, true)
      |> Keyword.put(:account_notify, true)
    )

    Application.put_env(
      :elixircd,
      :sasl,
      plain: [enabled: true, require_tls: false],
      max_attempts_per_connection: 3,
      session_timeout_ms: 60_000
    )

    :ok
  end

  describe "handle/2 - AUTHENTICATE - already registered" do
    test "rejects AUTHENTICATE after registration" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: true)
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 462 #{user.nick} :You may not reregister\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE - already authenticated" do
    test "rejects AUTHENTICATE when already authenticated via SASL" do
      Memento.transaction!(fn ->
        user =
          insert(:user,
            registered: false,
            capabilities: ["SASL"],
            cap_negotiating: true,
            identified_as: "testuser",
            sasl_authenticated: true
          )

        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        # When user is not registered yet, nick might be nil, so we use "*"
        expected_nick = if user.nick, do: user.nick, else: "*"

        assert_sent_messages([
          {user.pid, ":irc.test 907 #{expected_nick} :You have already authenticated using SASL\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE - missing parameters" do
    test "rejects AUTHENTICATE without parameters" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "AUTHENTICATE", params: []}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 461 * AUTHENTICATE :Not enough parameters\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE - without SASL capability" do
    test "rejects AUTHENTICATE when SASL capability not negotiated" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: [])
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 421 * AUTHENTICATE :You must negotiate SASL capability first\r\n"}
        ])
      end)
    end

    test "rejects AUTHENTICATE when CAP negotiation is not active" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: false)
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 451 * :You have not registered\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE - mechanism selection" do
    test "starts PLAIN authentication" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true)
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"}
        ])

        # Verify session was created
        assert {:ok, _session} = SaslSessions.get(user.pid)
      end)
    end

    test "rejects unsupported mechanism" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true)
        message = %Message{command: "AUTHENTICATE", params: ["EXTERNAL"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 908 * PLAIN :are available SASL mechanisms\r\n"},
          {user.pid, ":irc.test 904 * :SASL mechanism not supported\r\n"}
        ])
      end)
    end

    test "rejects authentication when SASL is disabled" do
      Application.put_env(:elixircd, :capabilities, sasl: false)

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true)
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 908 * :\r\n"},
          {user.pid, ":irc.test 904 * :SASL authentication is not enabled\r\n"}
        ])
      end)
    end

    test "rejects authentication when mechanism is disabled" do
      Application.put_env(:elixircd, :sasl, plain: [enabled: false])

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true)
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 908 * PLAIN :are available SASL mechanisms\r\n"},
          {user.pid, ":irc.test 904 * :SASL mechanism is disabled by server configuration\r\n"}
        ])
      end)
    end

    test "rejects authentication after max attempts" do
      Memento.transaction!(fn ->
        # Set attempts to 3, which is the limit (attempts will be 3 >= 3)
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true, sasl_attempts: 3)
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        # User should be rejected
        expected_nick = if user.nick, do: user.nick, else: "*"

        assert_sent_messages([
          {user.pid, ":irc.test 904 #{expected_nick} :Too many SASL authentication attempts\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE - aborting" do
    test "aborts authentication with *" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true)

        # Start authentication
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        message = %Message{command: "AUTHENTICATE", params: ["*"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 906 * :SASL authentication aborted\r\n"}
        ])

        # Verify session was deleted
        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
      end)
    end

    test "rejects abort when no session exists" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true)
        message = %Message{command: "AUTHENTICATE", params: ["*"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 904 * :SASL authentication is not in progress\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE - PLAIN authentication" do
    test "successfully authenticates with valid credentials" do
      Memento.transaction!(fn ->
        # Create a registered user
        registered_nick = insert(:registered_nick, nickname: "testuser", password: "password123")
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true, nick: "testnick")

        # Start authentication
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        # Send credentials: authzid \0 authcid \0 password
        credentials = Base.encode64("\0testuser\0password123")
        message = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message)

        # Factory creates users with ident="~username" and hostname="hostname"
        assert_sent_messages([
          {user.pid,
           ":irc.test 900 testnick testnick!~username@hostname testuser :You are now logged in as testuser\r\n"},
          {user.pid, ":irc.test 903 testnick :SASL authentication successful\r\n"}
        ])

        # Verify session was deleted
        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)

        # Verify user was updated
        updated_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert updated_user.identified_as == "testuser"
        assert updated_user.sasl_authenticated == true
        assert "r" in updated_user.modes

        # Verify registered nick was updated
        updated_nick = Memento.Query.read(ElixIRCd.Tables.RegisteredNick, registered_nick.nickname_key)
        assert updated_nick.last_seen_at != nil
      end)
    end

    test "rejects authentication with invalid password" do
      Memento.transaction!(fn ->
        # Create a registered user
        insert(:registered_nick, nickname: "testuser", password: "password123")
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true)

        # Start authentication
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        # Send credentials with wrong password
        credentials = Base.encode64("\0testuser\0wrongpassword")
        message = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 904 * :SASL authentication failed\r\n"}
        ])

        # Verify session was deleted
        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
      end)
    end

    test "rejects authentication with non-existent user" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true)

        # Start authentication
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        # Send credentials for non-existent user
        credentials = Base.encode64("\0nonexistent\0password")
        message = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 904 * :SASL authentication failed\r\n"}
        ])

        # Verify session was deleted
        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
      end)
    end

    test "rejects authentication with invalid base64" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true)

        # Start authentication
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        message = %Message{command: "AUTHENTICATE", params: ["not-valid-base64!!!"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 904 * :SASL authentication failed: Invalid credentials format\r\n"}
        ])

        # Verify session was deleted
        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
      end)
    end

    test "rejects authentication with invalid PLAIN format" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true)

        # Start authentication
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        # Send credentials without proper format (missing parts)
        credentials = Base.encode64("invalid")
        message = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 904 * :SASL authentication failed: Invalid credentials format\r\n"}
        ])

        # Verify session was deleted
        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
      end)
    end

    test "rejects PLAIN authentication over non-TLS when required" do
      Application.put_env(:elixircd, :sasl, plain: [enabled: true, require_tls: true])

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true, transport: :tcp)

        # Start authentication
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        credentials = Base.encode64("\0testuser\0password123")
        message = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 904 * :PLAIN mechanism requires TLS connection\r\n"}
        ])

        # Verify session was deleted
        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
      end)
    end

    test "allows PLAIN authentication over TLS when required" do
      Application.put_env(:elixircd, :sasl, plain: [enabled: true, require_tls: true])

      Memento.transaction!(fn ->
        # Create a registered user
        insert(:registered_nick, nickname: "testuser", password: "password123")
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true, transport: :tls)

        # Start authentication
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        credentials = Base.encode64("\0testuser\0password123")
        message = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message)

        # Factory creates users with ident="~username" and hostname="hostname"
        assert_sent_messages([
          {user.pid,
           ":irc.test 900 #{user.nick} #{user.nick}!~username@hostname testuser :You are now logged in as testuser\r\n"},
          {user.pid, ":irc.test 903 #{user.nick} :SASL authentication successful\r\n"}
        ])
      end)
    end

    test "rejects authentication with too long message" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true)

        # Start authentication
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        # Send a message that's too long (> 400 characters)
        long_message = String.duplicate("A", 401)
        message = %Message{command: "AUTHENTICATE", params: [long_message]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 905 * :SASL message too long\r\n"}
        ])

        # Verify session was deleted
        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
      end)
    end

    test "handles continuation of authentication data" do
      Memento.transaction!(fn ->
        # Create a registered user
        insert(:registered_nick, nickname: "testuser", password: "password123")
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true)

        # Start authentication
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        # Send + to indicate continuation (client says continue with buffered data)
        message1 = %Message{command: "AUTHENTICATE", params: ["+"]}
        assert :ok = Authenticate.handle(user, message1)

        # Should fail because buffer is empty (nick is * because user not registered)
        assert_sent_messages([
          {user.pid, ":irc.test 904 * :SASL authentication failed: Invalid credentials format\r\n"}
        ])
      end)
    end

    test "handles authentication when no session exists" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true)

        # Try to send auth data without starting a session
        credentials = Base.encode64("\0testuser\0password123")
        message = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message)

        # Should treat as mechanism selection (not session data)
        # Since credentials is not a known mechanism, should fail
        assert_sent_messages([
          {user.pid, ":irc.test 908 * PLAIN :are available SASL mechanisms\r\n"},
          {user.pid, ":irc.test 904 * :SASL mechanism not supported\r\n"}
        ])
      end)
    end

    test "handles PLAIN auth with authzid instead of authcid" do
      Memento.transaction!(fn ->
        # Create a registered user
        insert(:registered_nick, nickname: "testuser", password: "password123")
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true)

        # Start authentication
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        # Send credentials with authzid set, authcid empty
        # Format: authzid \0 authcid \0 password
        credentials = Base.encode64("testuser\0\0password123")
        message = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 900 #{user.nick} #{user.nick}!~username@hostname testuser :You are now logged in as testuser\r\n"},
          {user.pid, ":irc.test 903 #{user.nick} :SASL authentication successful\r\n"}
        ])
      end)
    end

    test "handles data when session no longer exists during auth data" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true)

        # Create a session
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        # Mock SaslSessions.get to return error (simulating race condition)
        Mimic.stub(SaslSessions, :get, fn _pid -> {:error, :sasl_session_not_found} end)

        # Try to send credentials
        credentials = Base.encode64("\0testuser\0password123")
        message = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message)

        # Should get error about session not in progress (covers lines 339-350)
        assert_sent_messages([
          {user.pid, ":irc.test 904 * :SASL authentication is not in progress\r\n"}
        ])
      end)
    end

    test "handles fragmented message requiring continuation" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true)

        # Start authentication
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        # Send exactly 400 chars without ending = to trigger continuation
        part1 = String.duplicate("A", 400)
        message1 = %Message{command: "AUTHENTICATE", params: [part1]}

        assert :ok = Authenticate.handle(user, message1)

        # Server should send + to request more data (line 380-383 coverage)
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"}
        ])

        # Verify session buffer was updated with the data
        {:ok, session} = SaslSessions.get(user.pid)
        assert String.length(session.buffer) == 400
      end)
    end

    test "handles unsupported mechanism in session (defensive case)" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true)

        # Create session with unsupported mechanism (this shouldn't normally happen)
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "EXTERNAL",
          buffer: "test"
        })

        # Try to send auth data with + (continuation)
        message = %Message{command: "AUTHENTICATE", params: ["+"]}
        assert :ok = Authenticate.handle(user, message)

        # Should reject as unsupported mechanism (covers line 392)
        assert_sent_messages([
          {user.pid, ":irc.test 908 * PLAIN :are available SASL mechanisms\r\n"},
          {user.pid, ":irc.test 904 * :SASL mechanism not supported\r\n"}
        ])
      end)
    end

    test "sends ACCOUNT notification to watchers when account-notify is supported" do
      Memento.transaction!(fn ->
        # Create a registered user
        insert(:registered_nick, nickname: "testuser", password: "password123")
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true, nick: "testnick")

        # Create a watcher user that has ACCOUNT-NOTIFY capability
        watcher = insert(:user, nick: "watcher", capabilities: ["ACCOUNT-NOTIFY"])

        # Start authentication
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        # Mock Users.get_in_shared_channels_with_capability to return the watcher
        # Use expect to be specific about this call only
        Mimic.expect(Users, :get_in_shared_channels_with_capability, 1, fn _user, "ACCOUNT-NOTIFY", true ->
          [watcher]
        end)

        # Send credentials
        credentials = Base.encode64("\0testuser\0password123")
        message = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message)

        # The ACCOUNT notification is sent with the user's nick from when notify_account_change is called
        # At that point, the user may not have completed registration yet, so nick might be *
        # Verify ACCOUNT notification was sent to watcher (covers lines 407-410)
        assert_sent_messages([
          {user.pid,
           ":irc.test 900 testnick testnick!~username@hostname testuser :You are now logged in as testuser\r\n"},
          {user.pid, ":irc.test 903 testnick :SASL authentication successful\r\n"},
          {watcher.pid, ":* ACCOUNT testuser\r\n"}
        ])
      end)
    end

    test "does not send ACCOUNT notification when account-notify is disabled" do
      Application.put_env(:elixircd, :capabilities, sasl: true, account_notify: false)

      Memento.transaction!(fn ->
        # Create a registered user
        insert(:registered_nick, nickname: "testuser", password: "password123")
        user = insert(:user, registered: false, capabilities: ["SASL"], cap_negotiating: true, nick: "testnick")

        # Create a watcher user
        watcher = insert(:user, nick: "watcher", capabilities: ["ACCOUNT-NOTIFY"])

        # Start authentication
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        # Mock Users.get_in_shared_channels_with_capability to return the watcher
        Mimic.stub(Users, :get_in_shared_channels_with_capability, fn _user, "ACCOUNT-NOTIFY", true ->
          [watcher]
        end)

        # Send credentials
        credentials = Base.encode64("\0testuser\0password123")
        message = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message)

        # Verify ACCOUNT notification was NOT sent because capability is disabled
        assert_sent_messages([
          {user.pid,
           ":irc.test 900 testnick testnick!~username@hostname testuser :You are now logged in as testuser\r\n"},
          {user.pid, ":irc.test 903 testnick :SASL authentication successful\r\n"}
        ])
      end)
    end
  end
end
