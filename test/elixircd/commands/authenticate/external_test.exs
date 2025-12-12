defmodule ElixIRCd.Commands.Authenticate.ExternalTest do
  use ElixIRCd.DataCase, async: false
  use ElixIRCd.MessageCase
  use Mimic

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Authenticate.External
  alias ElixIRCd.Commands.Authenticate
  alias ElixIRCd.Message
  alias ElixIRCd.Tables.User

  setup do
    Mimic.copy(:public_key)

    original_cap = Application.get_env(:elixircd, :capabilities)
    original_sasl = Application.get_env(:elixircd, :sasl)

    on_exit(fn ->
      Application.put_env(:elixircd, :capabilities, original_cap)
      Application.put_env(:elixircd, :sasl, original_sasl)
    end)

    Application.put_env(:elixircd, :capabilities, (original_cap || []) |> Keyword.put(:sasl, true))

    Application.put_env(:elixircd, :sasl,
      external: [enabled: true, require_client_cert: true],
      plain: [enabled: true],
      scram: [enabled: true]
    )

    :ok
  end

  describe "process/2" do
    test "rejects non-TLS connection" do
      Memento.transaction!(fn ->
        user = insert(:user, transport: :tcp)

        assert {:error, "EXTERNAL requires TLS connection"} = External.process(user, "+")
      end)
    end

    test "rejects non-TLS connection with empty payload" do
      Memento.transaction!(fn ->
        user = insert(:user, transport: :tcp)

        assert {:error, "EXTERNAL requires TLS connection"} = External.process(user, "")
      end)
    end

    test "rejects non-TLS connection with = payload" do
      Memento.transaction!(fn ->
        user = insert(:user, transport: :tcp)

        assert {:error, "EXTERNAL requires TLS connection"} = External.process(user, "=")
      end)
    end

    test "rejects TLS connection without certificate (not implemented)" do
      Memento.transaction!(fn ->
        user = insert(:user, transport: :tls)

        assert {:error, _} = External.process(user, "+")
      end)
    end

    test "rejects WSS connection without certificate (not implemented)" do
      Memento.transaction!(fn ->
        user = insert(:user, transport: :wss)

        assert {:error, _} = External.process(user, "+")
      end)
    end

    test "rejects invalid payload" do
      Memento.transaction!(fn ->
        user = insert(:user, transport: :tls)

        assert {:error, "EXTERNAL mechanism requires empty payload"} =
                 External.process(user, "invalid")
      end)
    end
  end

  describe "Authenticate.handle/2 with EXTERNAL" do
    @tag :capture_log
    test "fails when certificate is not verified" do
      Memento.transaction!(fn ->
        _ = insert(:registered_nick, nickname: "CertUser", password_hash: Argon2.hash_pwd_salt("pass"))

        user =
          insert(:user,
            registered: false,
            nick: "TempNick",
            capabilities: ["SASL"],
            transport: :tls,
            tls_peer_cert: "dummy",
            tls_cert_verified: false
          )

        msg1 = %Message{command: "AUTHENTICATE", params: ["EXTERNAL"]}
        assert :ok = Authenticate.handle(user, msg1)

        user = Memento.Query.read(User, user.pid)
        msg2 = %Message{command: "AUTHENTICATE", params: ["+"]}
        assert :ok = Authenticate.handle(user, msg2)

        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 904 * :Client certificate not verified\r\n"}
        ])
      end)
    end

    @tag :capture_log
    test "fails when no client certificate is provided" do
      Memento.transaction!(fn ->
        user =
          insert(:user,
            registered: false,
            nick: "TempNick",
            capabilities: ["SASL"],
            transport: :tls,
            tls_peer_cert: nil,
            tls_cert_verified: true
          )

        msg1 = %Message{command: "AUTHENTICATE", params: ["EXTERNAL"]}
        assert :ok = Authenticate.handle(user, msg1)

        user = Memento.Query.read(User, user.pid)
        msg2 = %Message{command: "AUTHENTICATE", params: ["+"]}
        assert :ok = Authenticate.handle(user, msg2)

        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 904 * :No client certificate provided\r\n"}
        ])
      end)
    end

    @tag :capture_log
    test "fails when certificate identity is not registered" do
      Memento.transaction!(fn ->
        expect(:public_key, :pkix_decode_cert, fn _bin, :otp ->
          {:OTPCertificate, build_tbs("UnregisteredCN"), nil, nil}
        end)

        user =
          insert(:user,
            registered: false,
            nick: "TempNick",
            capabilities: ["SASL"],
            transport: :tls,
            tls_peer_cert: "dummy",
            tls_cert_verified: true
          )

        msg1 = %Message{command: "AUTHENTICATE", params: ["EXTERNAL"]}
        assert :ok = Authenticate.handle(user, msg1)

        user = Memento.Query.read(User, user.pid)
        msg2 = %Message{command: "AUTHENTICATE", params: ["+"]}
        assert :ok = Authenticate.handle(user, msg2)

        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 904 * :Certificate identity not registered: UnregisteredCN\r\n"}
        ])
      end)
    end

    @tag :capture_log
    test "fails when certificate cannot be decoded" do
      Memento.transaction!(fn ->
        user =
          insert(:user,
            registered: false,
            nick: "TempNick",
            capabilities: ["SASL"],
            transport: :tls,
            tls_peer_cert: "invalid-der",
            tls_cert_verified: true
          )

        msg1 = %Message{command: "AUTHENTICATE", params: ["EXTERNAL"]}
        assert :ok = Authenticate.handle(user, msg1)

        user = Memento.Query.read(User, user.pid)
        msg2 = %Message{command: "AUTHENTICATE", params: ["+"]}
        assert :ok = Authenticate.handle(user, msg2)

        assert_sent_messages([
          {user.pid, ":irc.test AUTHENTICATE +\r\n"},
          {user.pid, ":irc.test 904 * :Certificate decoding error\r\n"}
        ])
      end)
    end
  end

  defp build_tbs(cn) do
    subject = {:rdnSequence, [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, cn}}]]}
    validity = {:Validity, {:utcTime, ~c"240101000000Z"}, {:utcTime, ~c"340101000000Z"}}

    {:OTPTBSCertificate, :v3, 1, {:AlgorithmIdentifier, {1, 2, 840, 113_549, 1, 1, 11}, :NULL},
     subject, validity, subject, :asn1_NOVALUE, :asn1_NOVALUE, :asn1_NOVALUE, :asn1_NOVALUE}
  end
end
