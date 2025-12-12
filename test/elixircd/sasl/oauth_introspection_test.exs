defmodule ElixIRCd.Sasl.OAuthIntrospectionTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false
  use Mimic

  alias ElixIRCd.Sasl.OAuthIntrospection

  setup :set_mimic_global

  setup do
    Mimic.copy(HTTPoison)
    :ok
  end

  describe "introspect/1" do
    test "returns error when introspection is disabled" do
      original_config = Application.get_env(:elixircd, :sasl)
      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_config) end)

      Application.put_env(:elixircd, :sasl,
        oauthbearer: [
          introspection: [
            enabled: false
          ]
        ]
      )

      assert {:error, :introspection_disabled} = OAuthIntrospection.introspect("test_token")
    end

    @tag :capture_log
    test "returns active claims for valid token" do
      original_config = Application.get_env(:elixircd, :sasl)
      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_config) end)

      Application.put_env(:elixircd, :sasl,
        oauthbearer: [
          introspection: [
            enabled: true,
            endpoint: "http://localhost:8000/introspect",
            client_id: "test_client",
            client_secret: "test_secret",
            timeout_ms: 5000
          ]
        ]
      )

      # Mock successful HTTP response
      expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %{
           status_code: 200,
           body: Jason.encode!(%{"active" => true, "sub" => "testuser", "scope" => "irc"})
         }}
      end)

      assert {:ok, claims} = OAuthIntrospection.introspect("valid_token")
      assert claims["active"] == true
      assert claims["sub"] == "testuser"
    end

    @tag :capture_log
    test "returns error for inactive token" do
      original_config = Application.get_env(:elixircd, :sasl)
      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_config) end)

      Application.put_env(:elixircd, :sasl,
        oauthbearer: [
          introspection: [
            enabled: true,
            endpoint: "http://localhost:8000/introspect",
            client_id: "test_client",
            client_secret: "test_secret"
          ]
        ]
      )

      # Mock inactive token response
      expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
        {:ok,
         %{
           status_code: 200,
           body: Jason.encode!(%{"active" => false})
         }}
      end)

      assert {:error, :token_inactive} = OAuthIntrospection.introspect("expired_token")
    end

    @tag :capture_log
    test "returns error for failed HTTP request" do
      original_config = Application.get_env(:elixircd, :sasl)
      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_config) end)

      Application.put_env(:elixircd, :sasl,
        oauthbearer: [
          introspection: [
            enabled: true,
            endpoint: "http://localhost:8000/introspect",
            client_id: "test_client",
            client_secret: "test_secret"
          ]
        ]
      )

      # Mock network error
      expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
        {:error, %{reason: :econnrefused}}
      end)

      assert {:error, :network_error} = OAuthIntrospection.introspect("test_token")
    end

    @tag :capture_log
    test "returns error for non-200 status code" do
      original_config = Application.get_env(:elixircd, :sasl)
      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_config) end)

      Application.put_env(:elixircd, :sasl,
        oauthbearer: [
          introspection: [
            enabled: true,
            endpoint: "http://localhost:8000/introspect",
            client_id: "test_client",
            client_secret: "test_secret"
          ]
        ]
      )

      # Mock 500 error
      expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 500, body: "Internal Server Error"}}
      end)

      assert {:error, :introspection_failed} = OAuthIntrospection.introspect("test_token")
    end

    test "returns error for invalid JSON response" do
      original_config = Application.get_env(:elixircd, :sasl)
      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_config) end)

      Application.put_env(:elixircd, :sasl,
        oauthbearer: [
          introspection: [
            enabled: true,
            endpoint: "http://localhost:8000/introspect",
            client_id: "test_client",
            client_secret: "test_secret"
          ]
        ]
      )

      # Mock invalid JSON
      expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 200, body: "not json"}}
      end)

      assert {:error, :invalid_response} = OAuthIntrospection.introspect("test_token")
    end
  end
end
