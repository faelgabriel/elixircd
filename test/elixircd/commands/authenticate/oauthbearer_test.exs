defmodule ElixIRCd.Commands.Authenticate.OauthbearerTest do
  use ExUnit.Case, async: true
  use Mimic

  alias ElixIRCd.Commands.Authenticate.Oauthbearer
  alias ElixIRCd.Tables.User

  @secret "testsecret"

  setup do
    Mimic.copy(ElixIRCd.Sasl.OAuthIntrospection)

    original_config = Application.get_env(:elixircd, :sasl)

    Application.put_env(:elixircd, :sasl,
      oauthbearer: [
        enabled: true,
        require_tls: true,
        jwt: [
          issuer: "issuer",
          audience: "aud",
          algorithm: "HS256",
          secret_or_public_key: @secret,
          leeway: 0
        ],
        introspection: [
          enabled: false
        ]
      ]
    )

    on_exit(fn -> Application.put_env(:elixircd, :sasl, original_config) end)

    {:ok, user: build_user()}
  end

  describe "process/2" do
    test "handles invalid base64", %{user: user} do
      assert {:error, "invalid_request", "Invalid base64 encoding"} =
               Oauthbearer.process(user, "invalid!base64")
    end

    test "handles missing auth field", %{user: user} do
      payload = "n,,\x01\x01"
      payload_b64 = Base.encode64(payload)

      assert {:error, "invalid_request", "Invalid OAUTHBEARER format"} =
               Oauthbearer.process(user, payload_b64)
    end

    test "rejects when TLS is required but not used" do
      user = build_user(%{transport: :tcp})
      payload_b64 = build_oauth_payload(sign_token(%{"sub" => "user123", "exp" => future_time()}))

      assert {:error, "invalid_request", "OAUTHBEARER requires TLS connection"} =
               Oauthbearer.process(user, payload_b64)
    end

    test "handles expired token", %{user: user} do
      token = sign_token(%{"sub" => "user123", "exp" => System.system_time(:second) - 10})
      payload_b64 = build_oauth_payload(token)

      assert {:error, "invalid_token", "The access token has expired"} =
               Oauthbearer.process(user, payload_b64)
    end

    test "handles token without sub claim", %{user: user} do
      token = sign_token(%{"exp" => future_time()})
      payload_b64 = build_oauth_payload(token)

      assert {:error, "invalid_token", _} = Oauthbearer.process(user, payload_b64)
    end

    test "rejects token with invalid signature", %{user: user} do
      token = sign_token(%{"sub" => "user123", "exp" => future_time()}, "wrongsecret")
      payload_b64 = build_oauth_payload(token)

      assert {:error, "invalid_token", "The access token is invalid"} =
               Oauthbearer.process(user, payload_b64)
    end

    test "accepts valid token", %{user: user} do
      token =
        sign_token(%{
          "sub" => "user123",
          "exp" => future_time(),
          "iss" => "issuer",
          "aud" => "aud"
        })

      payload_b64 = build_oauth_payload(token)

      assert {:ok, "user123"} = Oauthbearer.process(user, payload_b64)
    end
  end

  describe "process/2 with introspection enabled" do
    setup do
      original_sasl = Application.get_env(:elixircd, :sasl)

      Application.put_env(:elixircd, :sasl,
        oauthbearer: [
          enabled: true,
          require_tls: true,
          jwt: [
            issuer: "issuer",
            audience: "aud",
            algorithm: "HS256",
            secret_or_public_key: @secret,
            leeway: 0
          ],
          introspection: [
            enabled: true
          ]
        ]
      )

      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_sasl) end)

      :ok
    end

    @tag :capture_log
    test "prefers active token via introspection" do
      expect(ElixIRCd.Sasl.OAuthIntrospection, :introspect, fn _token ->
        {:ok, %{"active" => true, "sub" => "introspected", "exp" => future_time(), "iss" => "issuer", "aud" => "aud"}}
      end)

      user = build_user()
      payload_b64 = build_oauth_payload("ignored_token")

      assert {:ok, "introspected"} = Oauthbearer.process(user, payload_b64)
    end

    @tag :capture_log
    test "falls back to JWT when introspection fails" do
      expect(ElixIRCd.Sasl.OAuthIntrospection, :introspect, fn _token ->
        {:error, :introspection_failed}
      end)

      user = build_user()

      token =
        sign_token(%{
          "sub" => "fallback",
          "exp" => future_time(),
          "iss" => "issuer",
          "aud" => "aud"
        })

      payload_b64 = build_oauth_payload(token)

      assert {:ok, "fallback"} = Oauthbearer.process(user, payload_b64)
    end

    @tag :capture_log
    test "returns invalid_token when introspection returns inactive" do
      expect(ElixIRCd.Sasl.OAuthIntrospection, :introspect, fn _token ->
        {:error, :token_inactive}
      end)

      user = build_user()
      payload_b64 = build_oauth_payload("inactive")

      assert {:error, "invalid_token", "The access token is invalid"} = Oauthbearer.process(user, payload_b64)
    end
  end

  describe "claim validation" do
    setup do
      original_config = Application.get_env(:elixircd, :sasl)

      Application.put_env(:elixircd, :sasl,
        oauthbearer: [
          enabled: true,
          require_tls: true,
          jwt: [
            issuer: "issuer",
            audience: "aud",
            algorithm: "HS256",
            secret_or_public_key: @secret,
            leeway: 0
          ],
          introspection: [
            enabled: false
          ]
        ]
      )

      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_config) end)

      {:ok, user: build_user()}
    end

    test "rejects wrong issuer", %{user: user} do
      token =
        sign_token(%{
          "sub" => "user123",
          "exp" => future_time(),
          "iss" => "wrong",
          "aud" => "aud"
        })

      payload_b64 = build_oauth_payload(token)

      assert {:error, "invalid_token", "The access token is invalid"} = Oauthbearer.process(user, payload_b64)
    end

    test "rejects wrong audience", %{user: user} do
      token =
        sign_token(%{
          "sub" => "user123",
          "exp" => future_time(),
          "iss" => "issuer",
          "aud" => "other"
        })

      payload_b64 = build_oauth_payload(token)

      assert {:error, "invalid_token", "The access token is invalid"} = Oauthbearer.process(user, payload_b64)
    end

    test "rejects non-integer exp claim", %{user: user} do
      token =
        sign_token(%{
          "sub" => "user123",
          "exp" => "not-int",
          "iss" => "issuer",
          "aud" => "aud"
        })

      payload_b64 = build_oauth_payload(token)

      assert {:error, "invalid_token", "The access token is invalid"} = Oauthbearer.process(user, payload_b64)
    end

    @tag :capture_log
    test "rejects unsupported JWT algorithm" do
      original_sasl = Application.get_env(:elixircd, :sasl)

      Application.put_env(:elixircd, :sasl,
        oauthbearer: [
          enabled: true,
          require_tls: true,
          jwt: [
            issuer: "issuer",
            audience: "aud",
            algorithm: "FOO",
            secret_or_public_key: @secret,
            leeway: 0
          ],
          introspection: [
            enabled: false
          ]
        ]
      )

      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_sasl) end)

      user = build_user()
      token = sign_token(%{"sub" => "user123", "exp" => future_time()})
      payload_b64 = build_oauth_payload(token)

      assert {:error, "invalid_token", "The access token is invalid"} = Oauthbearer.process(user, payload_b64)
    end
  end

  defp build_user(attrs \\ %{}) do
    defaults = %{
      pid: self(),
      transport: :tls,
      ip_address: {127, 0, 0, 1},
      port_connected: 6667,
      nick: "TestUser",
      hostname: "host",
      ident: "ident",
      realname: "real"
    }

    attrs
    |> Map.merge(defaults, fn _key, provided, _default -> provided end)
    |> User.new()
  end

  defp sign_token(claims) do
    sign_token(claims, @secret)
  end

  defp sign_token(claims, secret) do
    claims =
      claims
      |> Map.put_new("iss", "issuer")
      |> Map.put_new("aud", "aud")

    jwk = JOSE.JWK.from_oct(secret)
    jws = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, claims)
    {_alg, token} = JOSE.JWS.compact(jws)
    token
  end

  defp future_time, do: System.system_time(:second) + 3600

  defp build_oauth_payload(token) do
    "n,,\x01auth=Bearer #{token}\x01\x01"
    |> Base.encode64()
  end
end
