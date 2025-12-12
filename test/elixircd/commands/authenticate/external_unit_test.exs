defmodule ElixIRCd.Commands.Authenticate.ExternalUnitTest do
  use ElixIRCd.DataCase, async: false
  use Mimic

  import ElixIRCd.Factory
  alias Argon2

  alias ElixIRCd.Commands.Authenticate.External
  alias ElixIRCd.Tables.User

  setup do
    Mimic.copy(:public_key)
    original_sasl = Application.get_env(:elixircd, :sasl)

    Application.put_env(:elixircd, :sasl,
      external: [enabled: true, cert_mappings: %{}],
      oauthbearer: [enabled: false],
      scram: [enabled: true],
      plain: [enabled: true]
    )

    on_exit(fn -> Application.put_env(:elixircd, :sasl, original_sasl) end)

    :ok
  end

  describe "process/2" do
    test "returns error when TLS not used" do
      user = build_user(%{transport: :tcp})
      assert {:error, "EXTERNAL requires TLS connection"} = External.process(user, "+")
    end

    test "returns error when certificate cannot be decoded" do
      stub(:public_key, :pkix_decode_cert, fn _bin, :otp -> raise "decode error" end)

      user =
        build_user(%{
          transport: :tls,
          tls_peer_cert: "dummy",
          tls_cert_verified: true
        })

      assert {:error, "Certificate decoding error"} = External.process(user, "+")
    end

    test "authenticates when CN matches registered nick" do
      stub(:public_key, :pkix_decode_cert, fn _bin, :otp ->
        {:OTPCertificate, build_tbs("CertCN"), nil, nil}
      end)

      Memento.transaction!(fn ->
        insert(:registered_nick, nickname: "CertCN", password_hash: Argon2.hash_pwd_salt("pass"))

        user =
          build_user(%{
            transport: :tls,
            tls_peer_cert: "dummy",
            tls_cert_verified: true
          })

        assert {:ok, "CertCN"} = External.process(user, "+")
      end)
    end

    test "uses fingerprint mapping when CN missing" do
      tbs = build_tbs(nil)
      fingerprint_value = :crypto.hash(:sha256, :erlang.term_to_binary(tbs)) |> Base.encode16(case: :lower)

      Application.put_env(:elixircd, :sasl,
        external: [enabled: true, cert_mappings: %{fingerprint_value => "Mapped"}],
        oauthbearer: [enabled: false],
        scram: [enabled: true],
        plain: [enabled: true]
      )

      stub(:public_key, :pkix_decode_cert, fn _bin, :otp ->
        {:OTPCertificate, tbs, nil, nil}
      end)

      Memento.transaction!(fn ->
        insert(:registered_nick, nickname: "Mapped", password_hash: Argon2.hash_pwd_salt("pass"))

        user =
          build_user(%{
            transport: :tls,
            tls_peer_cert: "dummy",
            tls_cert_verified: true
          })

        assert {:ok, "Mapped"} = External.process(user, "+")
      end)
    end

    test "returns error when mapping missing" do
      tbs = build_tbs(nil)

      Application.put_env(:elixircd, :sasl,
        external: [enabled: true, cert_mappings: %{}],
        oauthbearer: [enabled: false],
        scram: [enabled: true],
        plain: [enabled: true]
      )

      stub(:public_key, :pkix_decode_cert, fn _bin, :otp ->
        {:OTPCertificate, tbs, nil, nil}
      end)

      Memento.transaction!(fn ->
        user =
          build_user(%{
            transport: :tls,
            tls_peer_cert: "dummy",
            tls_cert_verified: true
          })

        assert {:error, "No identity found in certificate"} = External.process(user, "+")
      end)
    end

    test "returns error when CN matches but user not registered" do
      stub(:public_key, :pkix_decode_cert, fn _bin, :otp ->
        {:OTPCertificate, build_tbs("UnregisteredUser"), nil, nil}
      end)

      Memento.transaction!(fn ->
        user =
          build_user(%{
            transport: :tls,
            tls_peer_cert: "dummy",
            tls_cert_verified: true
          })

        assert {:error, "Certificate identity not registered: UnregisteredUser"} = External.process(user, "+")
      end)
    end
  end

  defp build_tbs(nil) do
    {:OTPTBSCertificate, :v3, 1, algo(), issuer(), validity(), subject(nil), :asn1_NOVALUE, :asn1_NOVALUE,
     :asn1_NOVALUE, :asn1_NOVALUE}
  end

  defp build_tbs(cn) do
    {:OTPTBSCertificate, :v3, 1, algo(), issuer(), validity(), subject(cn), :asn1_NOVALUE, :asn1_NOVALUE, :asn1_NOVALUE,
     :asn1_NOVALUE}
  end

  defp algo, do: {:AlgorithmIdentifier, {1, 2, 840, 113_549, 1, 1, 11}, :NULL}
  defp issuer, do: {:rdnSequence, []}
  defp validity, do: {:Validity, {:utcTime, ~c"240101000000Z"}, {:utcTime, ~c"340101000000Z"}}

  defp subject(nil), do: {:rdnSequence, []}

  defp subject(cn) do
    {:rdnSequence, [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, cn}}]]}
  end

  defp build_user(attrs) do
    defaults = %{
      pid: self(),
      transport: :tls,
      tls_peer_cert: "dummy",
      tls_cert_verified: true,
      nick: "TempNick",
      capabilities: ["SASL"],
      ip_address: {127, 0, 0, 1},
      port_connected: 6667
    }

    attrs
    |> Map.merge(defaults, fn _k, v, _d -> v end)
    |> User.new()
  end
end
