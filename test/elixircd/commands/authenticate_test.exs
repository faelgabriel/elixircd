defmodule ElixIRCd.Commands.AuthenticateTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  alias ElixIRCd.Commands.Authenticate
  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.SaslSessions
  alias ElixIRCd.Tables.ScramCredential
  alias ElixIRCd.Factory

  defp insert(type, attrs)

  defp insert(:user, attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:transport, :tls)
      |> Map.put_new(:capabilities, ["SASL"])

    Factory.insert(:user, attrs)
  end

  defp insert(type, attrs), do: Factory.insert(type, Map.new(attrs))

  describe "handle/2 - AUTHENTICATE with registered user" do
    test "rejects AUTHENTICATE after user handshake is complete" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: true)
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 462 #{user.nick} :You may not reregister\r\n"}
        ])
      end)
    end

    test "rejects AUTHENTICATE if already authenticated via SASL" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, identified_as: "testuser", sasl_authenticated: true)
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 907 * :You have already authenticated using SASL\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE without parameters" do
    test "returns error when no mechanism is provided" do
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

  describe "handle/2 - AUTHENTICATE mechanism selection" do
    test "accepts PLAIN mechanism and requests credentials" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"}
        ])

        # Verify SASL session was created
        session = Memento.Query.read(ElixIRCd.Tables.SaslSession, user.pid)
        assert session != nil
        assert session.mechanism == "PLAIN"
        assert session.buffer == ""
      end)
    end

    test "rejects unsupported mechanism" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "AUTHENTICATE", params: ["UNSUPPORTED-MECH"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 908 * PLAIN,SCRAM-SHA-256,SCRAM-SHA-512,EXTERNAL,OAUTHBEARER :are available SASL mechanisms\r\n"},
          {user.pid, ":irc.test 904 * :SASL mechanism not supported\r\n"}
        ])
      end)
    end

    test "rejects authentication when SASL is disabled" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, false)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 908 * :\r\n"},
          {user.pid, ":irc.test 904 * :SASL authentication is not enabled\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - additional branches" do
    setup do
      original_cap = Application.get_env(:elixircd, :capabilities)
      original_sasl = Application.get_env(:elixircd, :sasl)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, original_cap)
        Application.put_env(:elixircd, :sasl, original_sasl)
      end)

      :ok
    end

    test "rejects when SASL is disabled" do
      Application.put_env(:elixircd, :capabilities, Keyword.put([], :sasl, false))
      Application.put_env(:elixircd, :sasl, [])

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"])
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 908 * :\r\n"},
          {user.pid, ":irc.test 904 * :SASL authentication is not enabled\r\n"}
        ])
      end)
    end

    test "rejects disabled mechanism" do
      Application.put_env(:elixircd, :capabilities, Keyword.put([], :sasl, true))

      Application.put_env(:elixircd, :sasl,
        plain: [enabled: true],
        scram: [enabled: true],
        external: [enabled: false],
        oauthbearer: [enabled: false]
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"])
        message = %Message{command: "AUTHENTICATE", params: ["OAUTHBEARER"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 908 * PLAIN,SCRAM-SHA-256,SCRAM-SHA-512,EXTERNAL,OAUTHBEARER :are available SASL mechanisms\r\n"},
          {user.pid, ":irc.test 904 * :SASL mechanism is disabled by server configuration\r\n"}
        ])
      end)
    end

    test "aborts when session not in progress" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)
        message = %Message{command: "AUTHENTICATE", params: ["*"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 904 * :SASL authentication is not in progress\r\n"}
        ])
      end)
    end

    test "aborts and clears existing session" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false)

        session = %ElixIRCd.Tables.SaslSession{
          user_pid: user.pid,
          mechanism: "PLAIN",
          buffer: "",
          created_at: DateTime.utc_now()
        }

        Memento.Query.write(session)

        message = %Message{command: "AUTHENTICATE", params: ["*"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 906 * :SASL authentication aborted\r\n"}
        ])

        refute ElixIRCd.Repositories.SaslSessions.exists?(user.pid)
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE PLAIN with credentials" do
    test "successfully authenticates with valid credentials" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        # Create a registered nick
        password = "testpassword"
        password_hash = Argon2.hash_pwd_salt(password)

        _registered_nick =
          insert(:registered_nick,
            nickname: "TestUser",
            password_hash: password_hash
          )

        # Start authentication
        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL
        message1 = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send credentials: base64(username\0username\0password)
        credentials = Base.encode64("TestUser\0TestUser\0#{password}")
        message2 = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify success messages
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 900 * * TestUser :You are now logged in as TestUser\r\n"},
          {user.pid, ":irc.test 903 * :SASL authentication successful\r\n"}
        ])

        # Verify user state was updated
        final_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert final_user.identified_as == "TestUser"
        assert final_user.sasl_authenticated == true
        assert "r" in final_user.modes

        # Verify SASL session was cleaned up
        session = Memento.Query.read(ElixIRCd.Tables.SaslSession, user.pid)
        assert session == nil
      end)
    end

    test "fails authentication with invalid password" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        # Create a registered nick
        password_hash = Argon2.hash_pwd_salt("correctpassword")

        insert(:registered_nick,
          nickname: "TestUser",
          password_hash: password_hash
        )

        # Start authentication
        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL
        message1 = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send wrong credentials
        credentials = Base.encode64("TestUser\0TestUser\0wrongpassword")
        message2 = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify failure message
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 904 * :SASL authentication failed\r\n"}
        ])

        # Verify user state was reset
        final_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert final_user.identified_as == nil

        # Verify SASL session was cleaned up
        session = Memento.Query.read(ElixIRCd.Tables.SaslSession, user.pid)
        assert session == nil
      end)
    end

    test "fails authentication with non-existent user" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL
        message1 = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send credentials for non-existent user
        credentials = Base.encode64("NonExistent\0NonExistent\0password")
        message2 = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify failure message
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 904 * :SASL authentication failed\r\n"}
        ])

        # Verify user state was reset
        final_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert final_user.identified_as == nil

        # Verify SASL session was cleaned up
        session = Memento.Query.read(ElixIRCd.Tables.SaslSession, user.pid)
        assert session == nil
      end)
    end

    test "fails authentication with invalid base64" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL
        message1 = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send invalid base64
        message2 = %Message{command: "AUTHENTICATE", params: ["invalid!base64@data"]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify failure message
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 904 * :SASL authentication failed: Invalid credentials format\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE abort" do
    test "aborts authentication in progress" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL
        message1 = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Abort authentication
        message2 = %Message{command: "AUTHENTICATE", params: ["*"]}
        assert :ok = Authenticate.handle(user, message2)

        # Verify abort message
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 906 * :SASL authentication aborted\r\n"}
        ])

        # Verify SASL session was cleaned up
        session = Memento.Query.read(ElixIRCd.Tables.SaslSession, user.pid)
        assert session == nil
      end)
    end

    test "fails to abort when not in progress" do
      Memento.transaction!(fn ->
        user = insert(:user, registered: false, nick: "TempNick")

        # Try to abort without starting
        message = %Message{command: "AUTHENTICATE", params: ["*"]}
        assert :ok = Authenticate.handle(user, message)

        # Verify error message
        assert_sent_messages([
          {user.pid, ":irc.test 904 * :SASL authentication is not in progress\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE message too long" do
    test "rejects authentication data longer than 400 bytes" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL
        message1 = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send data longer than 400 bytes
        long_data = String.duplicate("A", 401)
        message2 = %Message{command: "AUTHENTICATE", params: [long_data]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify error message
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 905 * :SASL message too long\r\n"}
        ])

        # Verify SASL session was cleaned up
        session = Memento.Query.read(ElixIRCd.Tables.SaslSession, user.pid)
        assert session == nil
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE EXTERNAL mechanism" do
    test "rejects EXTERNAL authentication without TLS" do
      original_config = Application.get_env(:elixircd, :capabilities)
      original_sasl = Application.get_env(:elixircd, :sasl)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)
      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_sasl) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Application.put_env(:elixircd, :sasl, (original_sasl || []) |> Keyword.put(:external, enabled: true))

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, nick: "TempNick", transport: :tcp)

        # Initiate SASL with EXTERNAL
        message1 = %Message{command: "AUTHENTICATE", params: ["EXTERNAL"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send + to continue
        message2 = %Message{command: "AUTHENTICATE", params: ["+"]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify failure message (requires TLS)
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 904 * :EXTERNAL requires TLS connection\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE fragmented messages" do
    test "handles fragmented messages with +" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        password = "testpassword"
        password_hash = Argon2.hash_pwd_salt(password)

        _registered_nick =
          insert(:registered_nick,
            nickname: "TestUser",
            password_hash: password_hash
          )

        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL
        message1 = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send a partial fragment (exactly 400 bytes to trigger continuation)
        partial_data = String.duplicate("A", 400)
        message2 = %Message{command: "AUTHENTICATE", params: [partial_data]}
        assert :ok = Authenticate.handle(user, message2)

        # Verify continuation request
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test AUTHENTICATE +\r\n"}
        ])
      end)
    end

    test "processes data after sending +" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        password = "testpassword"
        password_hash = Argon2.hash_pwd_salt(password)

        _registered_nick =
          insert(:registered_nick,
            nickname: "TestUser",
            password_hash: password_hash
          )

        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL
        message1 = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get SASL session
        session = Memento.Query.read(ElixIRCd.Tables.SaslSession, user.pid)

        # Manually set a buffer in session
        SaslSessions.update(session, %{buffer: "partial"})

        # Send + to continue (should process existing buffer)
        message2 = %Message{command: "AUTHENTICATE", params: ["+"]}
        assert :ok = Authenticate.handle(user, message2)

        # Verify error (buffer "partial" is not valid base64 credentials)
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 904 * :SASL authentication failed: Invalid credentials format\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE SCRAM-SHA-256 mechanism" do
    test "fails with invalid client-first-message" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL with SCRAM-SHA-256
        message1 = %Message{command: "AUTHENTICATE", params: ["SCRAM-SHA-256"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send invalid client-first-message
        invalid_b64 = Base.encode64("invalid")
        message2 = %Message{command: "AUTHENTICATE", params: [invalid_b64]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify error was sent
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 904 * :SASL authentication failed\r\n"}
        ])
      end)
    end

    test "sends server-first-message on valid client-first" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        password = "scramtest"

        insert(:registered_nick,
          nickname: "testuser",
          password_hash: Argon2.hash_pwd_salt(password)
        )

        cred = ScramCredential.generate_from_password("testuser", password, :sha256, 4096)
        Memento.Query.write(cred)

        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL with SCRAM-SHA-256
        message1 = %Message{command: "AUTHENTICATE", params: ["SCRAM-SHA-256"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send valid client-first-message
        client_first = "n,,n=testuser,r=clientnonce123"
        client_first_b64 = Base.encode64(client_first)
        message2 = %Message{command: "AUTHENTICATE", params: [client_first_b64]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify server-first was sent and state was updated
        session = Memento.Query.read(ElixIRCd.Tables.SaslSession, user.pid)
        assert session.state != nil
        assert session.state.scram_step == 1
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE SCRAM-SHA-512 mechanism" do
    test "fails with invalid client-first-message" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL with SCRAM-SHA-512
        message1 = %Message{command: "AUTHENTICATE", params: ["SCRAM-SHA-512"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send invalid client-first-message
        invalid_b64 = Base.encode64("invalid")
        message2 = %Message{command: "AUTHENTICATE", params: [invalid_b64]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify error was sent
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 904 * :SASL authentication failed\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE OAUTHBEARER mechanism" do
    test "fails with invalid OAuth token" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL with OAUTHBEARER
        message1 = %Message{command: "AUTHENTICATE", params: ["OAUTHBEARER"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send OAuth payload with invalid token
        oauth_payload = "n,a=user@example.com,\x01auth=Bearer invalidtoken\x01\x01"
        oauth_b64 = Base.encode64(oauth_payload)
        message2 = %Message{command: "AUTHENTICATE", params: [oauth_b64]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify error was sent (OAuth error + SASL fail)
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert user.identified_as == nil
      end)
    end

    test "fails with valid JWT but non-existent user" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL with OAUTHBEARER
        message1 = %Message{command: "AUTHENTICATE", params: ["OAUTHBEARER"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Create a valid JWT with non-existent user
        header = Base.url_encode64(Jason.encode!(%{"alg" => "none"}), padding: false)
        claims = Jason.encode!(%{"sub" => "nonexistentuser123"})
        jwt_payload = Base.url_encode64(claims, padding: false)
        token = "#{header}.#{jwt_payload}.signature"

        oauth_payload = "n,,\x01auth=Bearer #{token}\x01\x01"
        oauth_b64 = Base.encode64(oauth_payload)
        message2 = %Message{command: "AUTHENTICATE", params: [oauth_b64]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify error was sent (including OAuth JSON error)
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert user.identified_as == nil
      end)
    end

    test "fails with invalid base64 payload" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL with OAUTHBEARER
        message1 = %Message{command: "AUTHENTICATE", params: ["OAUTHBEARER"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send invalid base64
        message2 = %Message{command: "AUTHENTICATE", params: ["invalid!base64"]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify error was sent
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert user.identified_as == nil
      end)
    end

    test "handles SCRAM authentication failure" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL with SCRAM-SHA-256
        message1 = %Message{command: "AUTHENTICATE", params: ["SCRAM-SHA-256"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send invalid SCRAM data
        invalid_scram = Base.encode64("invalid-scram-data")
        message2 = %Message{command: "AUTHENTICATE", params: [invalid_scram]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify error response
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 904 * :SASL authentication failed\r\n"}
        ])
      end)
    end

    test "rejects SASL data that exceeds maximum length" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL
        message1 = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send data that exceeds max length (401 characters, max is 400)
        long_data = String.duplicate("a", 401)
        long_b64 = Base.encode64(long_data)
        message2 = %Message{command: "AUTHENTICATE", params: [long_b64]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify error response
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 905 * :SASL message too long\r\n"}
        ])
      end)
    end

    test "successfully authenticates with valid OAuth token" do
      original_cap = Application.get_env(:elixircd, :capabilities)
      original_sasl = Application.get_env(:elixircd, :sasl)

      on_exit(fn ->
        Application.put_env(:elixircd, :capabilities, original_cap)
        Application.put_env(:elixircd, :sasl, original_sasl)
      end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_cap || []) |> Keyword.put(:sasl, true)
      )

      Application.put_env(:elixircd, :sasl,
        plain: [enabled: true],
        scram: [enabled: true],
        external: [enabled: false],
        oauthbearer: [
          enabled: true,
          require_tls: true,
          jwt: [algorithm: "HS256", secret_or_public_key: "testsecret", issuer: "test", audience: "test"]
        ]
      )

      Memento.transaction!(fn ->
        # Create a registered nick that matches the OAuth identity
        _registered_nick =
          insert(:registered_nick,
            nickname: "oauthuser",
            password_hash: Argon2.hash_pwd_salt("somepassword")
          )

        # Start authentication
        user = insert(:user, registered: false, nick: "TempNick")

        # Mock Oauthbearer.process to return success
        Mimic.expect(ElixIRCd.Commands.Authenticate.Oauthbearer, :process, fn _user, _data ->
          {:ok, "oauthuser"}
        end)

        # Initiate SASL
        message1 = %Message{command: "AUTHENTICATE", params: ["OAUTHBEARER"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send OAuth payload
        oauth_payload = "n,,\x01auth=Bearer validtoken\x01\x01"
        oauth_b64 = Base.encode64(oauth_payload)
        message2 = %Message{command: "AUTHENTICATE", params: [oauth_b64]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify success messages
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 900 * * oauthuser :You are now logged in as oauthuser\r\n"},
          {user.pid, ":irc.test 903 * :SASL authentication successful\r\n"}
        ])

        # Verify user state was updated
        final_user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)
        assert final_user.identified_as == "oauthuser"
        assert final_user.sasl_authenticated == true
        assert "r" in final_user.modes

        # Verify SASL session was cleaned up
        session = Memento.Query.read(ElixIRCd.Tables.SaslSession, user.pid)
        assert session == nil
      end)
    end
  end

  describe "handle/2 - AUTHENTICATE with invalid PLAIN format" do
    test "fails with empty authcid and authzid" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL
        message1 = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send credentials with empty authcid: base64("\0\0password")
        credentials = Base.encode64("\0\0password")
        message2 = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify failure message
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 904 * :SASL authentication failed: Invalid credentials format\r\n"}
        ])
      end)
    end

    test "fails with only one field" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL
        message1 = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send credentials with only one field: base64("justonestring")
        credentials = Base.encode64("justonestring")
        message2 = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify failure message
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 904 * :SASL authentication failed: Invalid credentials format\r\n"}
        ])
      end)
    end

    test "succeeds with authzid when authcid is empty" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        password = "testpassword"
        password_hash = Argon2.hash_pwd_salt(password)

        _registered_nick =
          insert(:registered_nick,
            nickname: "TestUser",
            password_hash: password_hash
          )

        user = insert(:user, registered: false, nick: "TempNick")

        # Initiate SASL
        message1 = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}
        assert :ok = Authenticate.handle(user, message1)

        # Get updated user
        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send credentials with authzid\0\0password (empty authcid) - should use authzid
        credentials = Base.encode64("TestUser\0\0#{password}")
        message2 = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message2)

        # Verify success message
        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 900 * * TestUser :You are now logged in as TestUser\r\n"},
          {user.pid, ":irc.test 903 * :SASL authentication successful\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - CAP SASL negotiation" do
    test "rejects AUTHENTICATE without SASL capability" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        # User without SASL capability
        user = insert(:user, registered: false, capabilities: [])
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 421 * AUTHENTICATE :You must negotiate SASL capability first\r\n"}
        ])
      end)
    end

    test "accepts AUTHENTICATE with SASL capability" do
      original_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        # User with SASL capability
        user = insert(:user, registered: false, capabilities: ["SASL"])
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - rate limiting" do
    test "rejects after max attempts" do
      original_config = Application.get_env(:elixircd, :sasl)
      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_config) end)

      Application.put_env(:elixircd, :sasl, max_attempts_per_connection: 2)

      original_cap_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_cap_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_cap_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"], sasl_attempts: 2)
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid, ":irc.test 904 * :Too many SASL authentication attempts\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - mechanism configuration" do
    test "rejects disabled mechanism" do
      original_sasl_config = Application.get_env(:elixircd, :sasl)
      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_sasl_config) end)

      Application.put_env(:elixircd, :sasl, plain: [enabled: false])

      original_cap_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_cap_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_cap_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        user = insert(:user, registered: false, capabilities: ["SASL"])
        message = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}

        assert :ok = Authenticate.handle(user, message)

        assert_sent_messages([
          {user.pid,
           ":irc.test 908 * PLAIN,SCRAM-SHA-256,SCRAM-SHA-512,EXTERNAL,OAUTHBEARER :are available SASL mechanisms\r\n"},
          {user.pid, ":irc.test 904 * :SASL mechanism is disabled by server configuration\r\n"}
        ])
      end)
    end
  end

  describe "handle/2 - TLS verification for PLAIN" do
    test "rejects PLAIN without TLS when required" do
      original_sasl_config = Application.get_env(:elixircd, :sasl)
      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_sasl_config) end)

      Application.put_env(:elixircd, :sasl, plain: [enabled: true, require_tls: true])

      original_cap_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_cap_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_cap_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        # Non-TLS connection
        user = insert(:user, registered: false, capabilities: ["SASL"], transport: :tcp)

        # Start PLAIN authentication
        message1 = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}
        assert :ok = Authenticate.handle(user, message1)

        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send credentials
        credentials = Base.encode64("test\0test\0password")
        message2 = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message2)

        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 904 * :PLAIN mechanism requires TLS connection\r\n"}
        ])
      end)
    end

    test "accepts PLAIN with TLS" do
      original_sasl_config = Application.get_env(:elixircd, :sasl)
      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_sasl_config) end)

      Application.put_env(:elixircd, :sasl, plain: [enabled: true, require_tls: true])

      original_cap_config = Application.get_env(:elixircd, :capabilities)
      on_exit(fn -> Application.put_env(:elixircd, :capabilities, original_cap_config) end)

      Application.put_env(
        :elixircd,
        :capabilities,
        (original_cap_config || []) |> Keyword.put(:sasl, true)
      )

      Memento.transaction!(fn ->
        password = "testpass"
        password_hash = Argon2.hash_pwd_salt(password)

        _registered_nick =
          insert(:registered_nick,
            nickname: "TestUser",
            password_hash: password_hash
          )

        # TLS connection
        user = insert(:user, registered: false, capabilities: ["SASL"], transport: :tls)

        # Start PLAIN authentication
        message1 = %Message{command: "AUTHENTICATE", params: ["PLAIN"]}
        assert :ok = Authenticate.handle(user, message1)

        user = Memento.Query.read(ElixIRCd.Tables.User, user.pid)

        # Send credentials
        credentials = Base.encode64("TestUser\0TestUser\0#{password}")
        message2 = %Message{command: "AUTHENTICATE", params: [credentials]}

        assert :ok = Authenticate.handle(user, message2)

        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 900 * * TestUser :You are now logged in as TestUser\r\n"},
          {user.pid, ":irc.test 903 * :SASL authentication successful\r\n"}
        ])
      end)
    end
  end
end
