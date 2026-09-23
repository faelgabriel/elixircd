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
  alias ElixIRCd.Sasl.ScramSha256
  alias ElixIRCd.Tables.RegisteredNick.Settings

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
    test "requires the SASL capability after registration" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: true)
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 421 #{user.nick} AUTHENTICATE :You must negotiate SASL capability first\r\n"}
        ])
      end)
    end

    test "starts SASL after registration when the capability is negotiated" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: true, capabilities: ["sasl"])

        assert :ok = Authenticate.handle(user, %Message{command: "AUTHENTICATE", params: ["PLAIN"]})

        assert_sent_messages([{user.pid, ":irc.test AUTHENTICATE +\r\n"}])
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE - already authenticated" do
    test "allows reauthentication when already authenticated via SASL" do
      Memento.transaction!(fn ->
        user =
          insert(:user,
            registered: false,
            capabilities: ["sasl"],
            cap_negotiating: true,
            identified_as: "testuser",
            sasl_authenticated: true
          )

        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([{user.pid, ":irc.test AUTHENTICATE +\r\n"}])
      end)
    end

    test "allows reauthentication before a nick is selected" do
      Memento.transaction!(fn ->
        user =
          insert(:user,
            registered: false,
            nick: nil,
            capabilities: ["sasl"],
            cap_negotiating: true,
            identified_as: "testuser",
            sasl_authenticated: true
          )

        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([{user.pid, ":irc.test AUTHENTICATE +\r\n"}])
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
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: false)
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
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)
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
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)
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
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 908 * :\r\n"},
          {user.pid, ":irc.test 904 * :SASL authentication is not enabled\r\n"}
        ])
      end)
    end

    test "does not advertise a disabled mechanism when rejecting it" do
      Application.put_env(:elixircd, :sasl, put_in(Application.fetch_env!(:elixircd, :sasl), [:plain, :enabled], false))

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 908 *  :are available SASL mechanisms\r\n"},
          {user.pid, ":irc.test 904 * :SASL mechanism not supported\r\n"}
        ])
      end)
    end

    test "rejects authentication after max attempts" do
      Memento.transaction!(fn ->
        # Set attempts to 3, which is the limit (attempts will be 3 >= 3)
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true, sasl_attempts: 3)
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
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)

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
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)
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
      Application.put_env(
        :elixircd,
        :sasl,
        Keyword.put(Application.fetch_env!(:elixircd, :sasl), :scram_sha_256,
          enabled: true,
          iterations: 4096
        )
      )

      Memento.transaction!(fn ->
        # Create a registered user
        registered_nick = insert(:registered_nick, nickname: "testuser", password: "password123")
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true, nick: "testnick")

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
        refute :r in updated_user.modes

        # Verify registered nick was updated
        updated_nick = Memento.Query.read(ElixIRCd.Tables.RegisteredNick, registered_nick.nickname_key)
        assert updated_nick.last_seen_at != nil
        assert is_map(updated_nick.scram_sha_256)
        assert Map.keys(updated_nick.scram_sha_256) |> Enum.sort() == [:iterations, :salt, :server_key, :stored_key]
      end)
    end

    test "rejects authentication with invalid password" do
      Memento.transaction!(fn ->
        # Create a registered user
        registered_nick = insert(:registered_nick, nickname: "testuser", password: "password123")
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)

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

        unchanged = Memento.Query.read(ElixIRCd.Tables.RegisteredNick, registered_nick.nickname_key)
        assert unchanged.scram_sha_256 == nil
      end)
    end

    test "does not authenticate an account while email verification is pending" do
      Memento.transaction!(fn ->
        insert(:registered_nick, nickname: "pending", password: "password123", verify_code: "code", verified_at: nil)
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)

        SaslSessions.create(%{user_pid: user.pid, mechanism: "PLAIN", buffer: ""})
        encoded = Base.encode64("\0pending\0password123")
        assert :ok = Authenticate.handle(user, %Message{command: "AUTHENTICATE", params: [encoded]})

        assert_sent_message_contains(user.pid, ~r/ 904 \* :SASL authentication failed\r\n/)
        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
        assert {:ok, unchanged} = Users.get_by_pid(user.pid)
        assert is_nil(unchanged.identified_as)
      end)
    end

    test "rejects authentication when grouped nick canonical account cannot be resolved" do
      Memento.transaction!(fn ->
        insert(:registered_nick,
          nickname: "aliasuser",
          account_name: "missingaccount",
          password_hash: Argon2.hash_pwd_salt("password123")
        )

        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)

        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        credentials = Base.encode64("\0aliasuser\0password123")
        message = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 904 * :SASL authentication failed\r\n"}
        ])

        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
      end)
    end

    test "rejects authentication with non-existent user" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)

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
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)

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
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)

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
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true, transport: :tcp)

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
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true, transport: :tls)

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

    test "rejects account authentication over a non-secure connection when SECURE is enabled" do
      Memento.transaction!(fn ->
        insert(:registered_nick,
          nickname: "secure_account",
          password: "password123",
          settings: Settings.new(%{secure: true})
        )

        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true, transport: :tcp)

        SaslSessions.create(%{user_pid: user.pid, mechanism: "PLAIN", buffer: ""})

        credentials = Base.encode64("\0secure_account\0password123")
        assert :ok = Authenticate.handle(user, %Message{command: "AUTHENTICATE", params: [credentials]})

        assert_sent_messages([
          {user.pid, ":irc.test 904 * :SASL authentication requires a secure TLS connection for this account\r\n"}
        ])
      end)
    end

    test "rejects authentication with too long message" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)

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
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)

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
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)

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
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)

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
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)

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

    for {nick, ident} <- [{nil, nil}, {"testnick", nil}, {nil, "~username"}] do
      test "authenticates before registration fields #{inspect({nick, ident})}" do
        Memento.transaction!(fn ->
          user =
            insert(:user,
              registered: false,
              nick: unquote(nick),
              ident: unquote(ident),
              capabilities: ["sasl"],
              cap_negotiating: true
            )

          insert(:registered_nick, nickname: "testuser", password_hash: Argon2.hash_pwd_salt("password"))
          SaslSessions.create(%{user_pid: user.pid, mechanism: "PLAIN", buffer: ""})

          assert :ok =
                   Authenticate.handle(user, %Message{
                     command: "AUTHENTICATE",
                     params: [Base.encode64("\0testuser\0password")]
                   })

          {:ok, authenticated} = Users.get_by_pid(user.pid)
          assert authenticated.sasl_authenticated
          assert authenticated.identified_as == "testuser"

          assert_sent_message_contains(
            user.pid,
            Regex.compile!(
              Regex.escape("900 #{user.nick || "*"} #{user.nick || "*"}!#{user.ident || "*"}@hostname testuser")
            )
          )

          assert_sent_messages_count_containing(user.pid, ~r/ 903 /, 1)
        end)
      end
    end

    test "limits total SASL data across individually valid chunks" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)
        SaslSessions.create(%{user_pid: user.pid, mechanism: "PLAIN", buffer: ""})
        chunk = %Message{command: "AUTHENTICATE", params: [String.duplicate("A", 400)]}
        for _ <- 1..40, do: assert(:ok = Authenticate.handle(user, chunk))
        assert_sent_messages_amount(user.pid, 0)
        {:ok, session} = SaslSessions.get(user.pid)
        assert byte_size(session.buffer) == 16_000
        assert :ok = Authenticate.handle(user, chunk)
        assert_sent_messages_count_containing(user.pid, ~r/ 904 /, 1)
        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
      end)
    end

    test "waits for terminator after a padded 400-byte chunk" do
      Memento.transaction!(fn ->
        password = String.duplicate("p", 288)
        payload = Base.encode64("\0testuser\0" <> password)
        assert byte_size(payload) == 400
        assert String.ends_with?(payload, "=")
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)
        insert(:registered_nick, nickname: "testuser", password_hash: Argon2.hash_pwd_salt(password))
        SaslSessions.create(%{user_pid: user.pid, mechanism: "PLAIN", buffer: ""})
        assert :ok = Authenticate.handle(user, %Message{command: "AUTHENTICATE", params: [payload]})
        assert_sent_messages_amount(user.pid, 0)
        assert {:ok, _} = SaslSessions.get(user.pid)
        assert :ok = Authenticate.handle(user, %Message{command: "AUTHENTICATE", params: ["+"]})
        assert_sent_messages_count_containing(user.pid, ~r/ 903 /, 1)
      end)
    end

    test "handles fragmented message requiring continuation" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)

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

        # Full chunks have no intermediate server response.
        assert_sent_messages_amount(user.pid, 0)

        # Verify session buffer was updated with the data
        {:ok, session} = SaslSessions.get(user.pid)
        assert String.length(session.buffer) == 400
      end)
    end

    test "handles unsupported mechanism in session (defensive case)" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)

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
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true, nick: "testnick")

        # Create a watcher user that has ACCOUNT-NOTIFY capability
        watcher = insert(:user, nick: "watcher", capabilities: ["account-notify"])

        # Start authentication
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        # Mock Users.get_in_shared_channels_with_capability to return the watcher
        # Use expect to be specific about this call only
        Mimic.expect(Users, :get_in_shared_channels_with_capability, 1, fn _user, "account-notify", true ->
          [watcher]
        end)

        # Send credentials
        credentials = Base.encode64("\0testuser\0password123")
        message = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message)

        # The ACCOUNT notification is sent with the user's nick from when notify_account_change is called
        # At that point, the user may not have completed registration yet, so nick might be *
        # Only the watcher negotiated account-notify; SASL numerics confirm the sender's login.
        assert_sent_messages([
          {user.pid,
           ":irc.test 900 testnick testnick!~username@hostname testuser :You are now logged in as testuser\r\n"},
          {user.pid, ":irc.test 903 testnick :SASL authentication successful\r\n"},
          {watcher.pid, ":* ACCOUNT testuser\r\n"}
        ])
      end)
    end

    test "preserves negotiated ACCOUNT notifications when advertisement is disabled" do
      Application.put_env(:elixircd, :capabilities, sasl: true, account_notify: false)

      Memento.transaction!(fn ->
        # Create a registered user
        insert(:registered_nick, nickname: "testuser", password: "password123")
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true, nick: "testnick")

        # Create a watcher user
        watcher = insert(:user, nick: "watcher", capabilities: ["account-notify"])

        # Start authentication
        SaslSessions.create(%{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: ""
        })

        # Mock Users.get_in_shared_channels_with_capability to return the watcher
        Mimic.stub(Users, :get_in_shared_channels_with_capability, fn _user, "account-notify", true ->
          [watcher]
        end)

        # Send credentials
        credentials = Base.encode64("\0testuser\0password123")
        message = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message)

        # SASL numerics are independent of ACCOUNT; the legacy watcher keeps its negotiated contract.
        assert_sent_messages([
          {user.pid,
           ":irc.test 900 testnick testnick!~username@hostname testuser :You are now logged in as testuser\r\n"},
          {user.pid, ":irc.test 903 testnick :SASL authentication successful\r\n"},
          {watcher.pid, ":* ACCOUNT testuser\r\n"}
        ])
      end)
    end
  end

  test "SASL success numerics and registered mode follow the current nickname without account-notify" do
    Memento.transaction!(fn ->
      insert(:registered_nick, nickname: "SaslAccount", password: "password")
      insert(:registered_nick, nickname: "SaslAlias", account_name: "SaslAccount")

      for {nick, expected_mode} <- [{nil, false}, {"sAsLaCcOuNt", true}, {"SaslAlias", true}, {"Unrelated", false}] do
        user = insert(:user, registered: false, nick: nick, capabilities: ["sasl"], cap_negotiating: true)
        SaslSessions.create(%{user_pid: user.pid, mechanism: "PLAIN", buffer: ""})
        Authenticate.handle(user, %Message{command: "AUTHENTICATE", params: [Base.encode64("\0SaslAccount\0password")]})
        {:ok, updated} = Users.get_by_pid(user.pid)
        assert updated.sasl_authenticated
        assert updated.identified_as == "SaslAccount"
        assert :r in updated.modes == expected_mode
        assert_sent_messages_count_containing(user.pid, ~r/ 900 /, 1)
        assert_sent_messages_count_containing(user.pid, ~r/ 903 /, 1)
        assert_sent_messages_count_containing(user.pid, ~r/ ACCOUNT /, 0)
      end
    end)
  end

  describe "handle/2 - AUTHENTICATE - SCRAM-SHA-256" do
    test "authenticates without transmitting the password" do
      Application.put_env(:elixircd, :sasl,
        plain: [enabled: true, require_tls: false],
        scram_sha_256: [enabled: true, iterations: 4096],
        max_attempts_per_connection: 3,
        session_timeout_ms: 60_000
      )

      password = "password123"
      credentials = ScramSha256.derive(password, 4096)

      Memento.transaction!(fn ->
        insert(:registered_nick, nickname: "scram_user", password: password, scram_sha_256: credentials)
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)

        assert :ok = Authenticate.handle(user, %Message{command: "AUTHENTICATE", params: ["SCRAM-SHA-256"]})
        assert_sent_messages([{user.pid, ":irc.test AUTHENTICATE +\r\n"}])

        client_first_bare = "n=scram_user,r=client-nonce"

        assert :ok =
                 Authenticate.handle(user, %Message{
                   command: "AUTHENTICATE",
                   params: [Base.encode64("n,," <> client_first_bare)]
                 })

        user_pid = user.pid
        [{^user_pid, server_message}] = Agent.get(@agent_name, &Enum.reverse/1)
        [":irc.test", "AUTHENTICATE", encoded_server_first] = server_message |> String.trim() |> String.split(" ")
        server_first = Base.decode64!(encoded_server_first)
        Agent.update(@agent_name, fn _ -> [] end)

        client_final = scram_client_final(password, client_first_bare, server_first)

        assert :ok =
                 Authenticate.handle(user, %Message{
                   command: "AUTHENTICATE",
                   params: [Base.encode64(client_final)]
                 })

        assert_sent_messages([
          {user.pid, ~r/^:irc\.test AUTHENTICATE [A-Za-z0-9+\/=]+\r\n$/},
          {user.pid,
           ":irc.test 900 #{user.nick} #{user.nick}!~username@hostname scram_user :You are now logged in as scram_user\r\n"},
          {user.pid, ":irc.test 903 #{user.nick} :SASL authentication successful\r\n"}
        ])
      end)
    end

    test "rejects a valid SCRAM proof while account verification is pending" do
      enable_scram()
      password = "password123"

      Memento.transaction!(fn ->
        insert(:registered_nick,
          nickname: "pending_scram",
          password: password,
          scram_sha_256: ScramSha256.derive(password, 4096),
          verify_code: "code",
          verified_at: nil
        )

        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)
        assert :ok = Authenticate.handle(user, %Message{command: "AUTHENTICATE", params: ["SCRAM-SHA-256"]})
        Agent.update(@agent_name, fn _ -> [] end)

        first = "n=pending_scram,r=client-nonce"

        assert :ok =
                 Authenticate.handle(user, %Message{command: "AUTHENTICATE", params: [Base.encode64("n,," <> first)]})

        user_pid = user.pid
        [{^user_pid, server_message}] = Agent.get(@agent_name, &Enum.reverse/1)
        encoded_server_first = server_message |> String.trim() |> String.split(" ") |> List.last()
        server_first = Base.decode64!(encoded_server_first)
        Agent.update(@agent_name, fn _ -> [] end)

        final = scram_client_final(password, first, server_first)
        assert :ok = Authenticate.handle(user, %Message{command: "AUTHENTICATE", params: [Base.encode64(final)]})

        assert_sent_message_contains(
          user.pid,
          ~r/ 904 \* :SASL authentication failed: Account verification is required/
        )

        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
        assert {:ok, unchanged} = Users.get_by_pid(user.pid)
        assert is_nil(unchanged.identified_as)
      end)
    end

    test "fails malformed SCRAM starts and clears the session" do
      enable_scram()

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)
        SaslSessions.create(%{user_pid: user.pid, mechanism: "SCRAM-SHA-256", buffer: ""})

        assert :ok =
                 Authenticate.handle(user, %Message{
                   command: "AUTHENTICATE",
                   params: [Base.encode64("malformed")]
                 })

        assert_sent_message_contains(user.pid, ~r/ 904 \* :SASL authentication failed/)
        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
      end)
    end

    test "uses fake credentials for unknown accounts and rejects the final proof" do
      enable_scram()

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)
        SaslSessions.create(%{user_pid: user.pid, mechanism: "SCRAM-SHA-256", buffer: ""})
        client_first = "n,,n=missing,r=client-nonce"

        assert :ok =
                 Authenticate.handle(user, %Message{
                   command: "AUTHENTICATE",
                   params: [Base.encode64(client_first)]
                 })

        Agent.update(@agent_name, fn _ -> [] end)

        assert :ok =
                 Authenticate.handle(user, %Message{
                   command: "AUTHENTICATE",
                   params: [Base.encode64("c=biws,r=wrong,p=AAAA")]
                 })

        assert_sent_message_contains(user.pid, ~r/ 904 \* :SASL authentication failed/)
        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE - ECDSA-NIST256P-CHALLENGE" do
    test "authenticates with a compressed P-256 key using the challenge directly as the digest" do
      Application.put_env(:elixircd, :sasl,
        plain: [enabled: true, require_tls: false],
        ecdsa: [enabled: true],
        max_attempts_per_connection: 3,
        session_timeout_ms: 60_000
      )

      {public_key, private_key} = :crypto.generate_key(:ecdh, :secp256r1)
      compressed_public_key = compress_public_key(public_key)

      Memento.transaction!(fn ->
        account =
          insert(:registered_nick,
            nickname: "ecdsa_account",
            settings: Settings.new(%{pubkey: Base.encode64(compressed_public_key)})
          )

        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true, transport: :tls)

        assert :ok =
                 Authenticate.handle(
                   user,
                   %Message{command: "AUTHENTICATE", params: ["ECDSA-NIST256P-CHALLENGE"]}
                 )

        assert_sent_messages([{user.pid, ":irc.test AUTHENTICATE +\r\n"}])

        assert :ok =
                 Authenticate.handle(
                   user,
                   %Message{command: "AUTHENTICATE", params: [Base.encode64(account.nickname)]}
                 )

        {:ok, session} = SaslSessions.get(user.pid)
        challenge = session.state.challenge

        assert_sent_messages([{user.pid, ":irc.test AUTHENTICATE #{Base.encode64(challenge)}\r\n"}])

        signature = :crypto.sign(:ecdsa, :sha256, {:digest, challenge}, [private_key, :secp256r1])

        assert :ok =
                 Authenticate.handle(
                   user,
                   %Message{command: "AUTHENTICATE", params: [Base.encode64(signature)]}
                 )

        assert_sent_messages([
          {user.pid, ~r/ 900 .* ecdsa_account :You are now logged in as ecdsa_account/},
          {user.pid, ~r/ 903 .* :SASL authentication successful/}
        ])
      end)
    end

    test "accepts an empty authorization identity and rejects a malformed signature" do
      Application.put_env(:elixircd, :sasl,
        plain: [enabled: true, require_tls: false],
        ecdsa: [enabled: true],
        max_attempts_per_connection: 3,
        session_timeout_ms: 60_000
      )

      {public_key, _private_key} = :crypto.generate_key(:ecdh, :secp256r1)
      compressed_public_key = compress_public_key(public_key)

      Memento.transaction!(fn ->
        account =
          insert(:registered_nick,
            nickname: "ecdsa_empty_authzid",
            settings: Settings.new(%{pubkey: Base.encode64(compressed_public_key)})
          )

        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true, transport: :tls)

        SaslSessions.create(%{user_pid: user.pid, mechanism: "ECDSA-NIST256P-CHALLENGE", buffer: ""})
        Authenticate.handle(user, %Message{command: "AUTHENTICATE", params: [Base.encode64(account.nickname <> <<0>>)]})
        {:ok, session} = SaslSessions.get(user.pid)

        Authenticate.handle(user, %Message{command: "AUTHENTICATE", params: [Base.encode64("bad")]})

        assert session.state.challenge != nil
        assert_sent_message_contains(user.pid, ":irc.test 904 * :SASL authentication failed\r\n")
      end)
    end

    test "rejects ECDSA authzids for another account or with extra separators" do
      Application.put_env(:elixircd, :sasl,
        plain: [enabled: true, require_tls: false],
        ecdsa: [enabled: true],
        max_attempts_per_connection: 3,
        session_timeout_ms: 60_000
      )

      {public_key, _private_key} = :crypto.generate_key(:ecdh, :secp256r1)
      compressed_public_key = compress_public_key(public_key)

      Memento.transaction!(fn ->
        account =
          insert(:registered_nick,
            nickname: "ecdsa_bad_authzid",
            settings: Settings.new(%{pubkey: Base.encode64(compressed_public_key)})
          )

        for encoded_account <- [
              account.nickname <> <<0>> <> "other",
              account.nickname <> <<0>> <> account.nickname <> <<0>>,
              account.nickname <> <<0>> <> account.nickname <> <<0>> <> "extra"
            ] do
          user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true, transport: :tls)

          SaslSessions.create(%{user_pid: user.pid, mechanism: "ECDSA-NIST256P-CHALLENGE", buffer: ""})
          Authenticate.handle(user, %Message{command: "AUTHENTICATE", params: [Base.encode64(encoded_account)]})

          assert_sent_message_contains(user.pid, ":irc.test 904 * :SASL authentication failed\r\n")
        end
      end)
    end

    test "rejects ECDSA accounts with malformed or invalid public keys" do
      Application.put_env(:elixircd, :sasl,
        plain: [enabled: true, require_tls: false],
        ecdsa: [enabled: true],
        max_attempts_per_connection: 3,
        session_timeout_ms: 60_000
      )

      invalid_point = <<2>> <> :binary.copy(<<255>>, 32)

      for encoded_key <- ["invalid", Base.encode64(invalid_point, padding: false)] do
        Memento.transaction!(fn ->
          account =
            insert(:registered_nick, nickname: "ecdsa_invalid_key", settings: Settings.new(%{pubkey: encoded_key}))

          user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true, transport: :tls)

          assert :ok =
                   Authenticate.handle(
                     user,
                     %Message{command: "AUTHENTICATE", params: ["ECDSA-NIST256P-CHALLENGE"]}
                   )

          assert :ok =
                   Authenticate.handle(
                     user,
                     %Message{command: "AUTHENTICATE", params: [Base.encode64(account.nickname)]}
                   )

          assert_sent_message_contains(user.pid, ":irc.test 904 * :SASL authentication failed\r\n")
        end)
      end
    end

    test "rejects an invalid mechanism through the defensive mechanism guard" do
      Application.put_env(:elixircd, :sasl,
        plain: [enabled: true, require_tls: false],
        ecdsa: [enabled: false],
        max_attempts_per_connection: 3,
        session_timeout_ms: 60_000
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)
        assert :ok = Authenticate.handle(user, %Message{command: "AUTHENTICATE", params: ["EXTERNAL"]})
        assert_sent_message_contains(user.pid, ":irc.test 904 * :SASL mechanism not supported\r\n")
      end)
    end

    test "rejects ECDSA authentication when the account has no usable public key" do
      Application.put_env(:elixircd, :sasl,
        plain: [enabled: true, require_tls: false],
        ecdsa: [enabled: true],
        max_attempts_per_connection: 3,
        session_timeout_ms: 60_000
      )

      Memento.transaction!(fn ->
        account = insert(:registered_nick, nickname: "without_key")
        user = insert(:user, registered: false, capabilities: ["sasl"], cap_negotiating: true)

        assert :ok =
                 Authenticate.handle(
                   user,
                   %Message{command: "AUTHENTICATE", params: ["ECDSA-NIST256P-CHALLENGE"]}
                 )

        assert :ok =
                 Authenticate.handle(
                   user,
                   %Message{command: "AUTHENTICATE", params: [Base.encode64(account.nickname)]}
                 )

        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 904 * :SASL authentication failed\r\n"}
        ])

        assert {:error, :sasl_session_not_found} = SaslSessions.get(user.pid)
      end)
    end
  end

  defp scram_client_final(password, client_first_bare, server_first) do
    attrs =
      server_first
      |> String.split(",")
      |> Map.new(fn part ->
        [key, value] = String.split(part, "=", parts: 2)
        {key, value}
      end)

    without_proof = "c=biws,r=#{attrs["r"]}"
    auth_message = client_first_bare <> "," <> server_first <> "," <> without_proof

    salted =
      :crypto.pbkdf2_hmac(
        :sha256,
        password,
        Base.decode64!(attrs["s"]),
        String.to_integer(attrs["i"]),
        32
      )

    client_key = :crypto.mac(:hmac, :sha256, salted, "Client Key")
    signature = :crypto.mac(:hmac, :sha256, :crypto.hash(:sha256, client_key), auth_message)
    without_proof <> ",p=" <> Base.encode64(:crypto.exor(client_key, signature))
  end

  defp enable_scram do
    Application.put_env(:elixircd, :sasl,
      plain: [enabled: true, require_tls: false],
      scram_sha_256: [enabled: true, iterations: 4096],
      max_attempts_per_connection: 3,
      session_timeout_ms: 60_000
    )
  end

  defp compress_public_key(public_key) do
    <<_prefix, x::binary-size(32), y::binary-size(32)>> = public_key
    prefix = if rem(:binary.last(y), 2) == 1, do: 3, else: 2
    <<prefix, x::binary>>
  end
end
