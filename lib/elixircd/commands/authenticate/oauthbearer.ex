defmodule ElixIRCd.Commands.Authenticate.Oauthbearer do
  @moduledoc """
  OAUTHBEARER SASL mechanism implementation.

  Supports OAuth 2.0 bearer token authentication as defined in RFC 7628.
  """

  require Logger

  alias ElixIRCd.Sasl.OAuthIntrospection

  @doc """
  Processes OAUTHBEARER authentication.

  Expects base64-encoded payload containing:
  - n,a=user@example.com (optional)
  - auth=Bearer TOKEN
  """
  @spec process(ElixIRCd.Tables.User.t(), String.t()) :: {:ok, String.t()} | {:error, String.t(), String.t()}
  def process(user, data) do
    sasl_config = Application.get_env(:elixircd, :sasl, [])
    require_tls = Keyword.get(sasl_config[:oauthbearer] || [], :require_tls, true)

    if require_tls and user.transport not in [:tls, :wss] do
      {:error, "invalid_request", "OAUTHBEARER requires TLS connection"}
    else
      do_process(data)
    end
  end

  defp do_process(data) do
    with {:ok, decoded} <- Base.decode64(data),
         {:ok, parsed} <- parse_oauth_payload(decoded),
         {:ok, identity} <- validate_token(parsed.token) do
      {:ok, identity}
    else
      :error ->
        {:error, "invalid_request", "Invalid base64 encoding"}

      {:error, :parse_error} ->
        {:error, "invalid_request", "Invalid OAUTHBEARER format"}

      {:error, :invalid_token} ->
        {:error, "invalid_token", "The access token is invalid"}

      {:error, :token_expired} ->
        {:error, "invalid_token", "The access token has expired"}
    end
  end

  defp parse_oauth_payload(payload) do
    # Format: n,a=user@example.com\x01auth=Bearer TOKEN\x01\x01
    # or: n,,\x01auth=Bearer TOKEN\x01\x01
    parts = String.split(payload, "\x01", trim: true)

    # Find auth= part
    token =
      Enum.find_value(parts, fn part ->
        case String.split(part, "=", parts: 2) do
          ["auth", "Bearer " <> token] -> token
          _ -> nil
        end
      end)

    # Find a= part (optional)
    user =
      Enum.find_value(parts, fn part ->
        case String.split(part, "=", parts: 2) do
          ["a", user] -> user
          _ -> nil
        end
      end)

    if token do
      {:ok, %{token: token, user: user}}
    else
      {:error, :parse_error}
    end
  end

  defp validate_token(token) do
    sasl_config = Application.get_env(:elixircd, :sasl, [])
    oauth_config = sasl_config[:oauthbearer] || []
    introspection_config = oauth_config[:introspection] || []
    jwt_config = oauth_config[:jwt] || []

    # Try introspection first if enabled
    if Keyword.get(introspection_config, :enabled, false) do
      case OAuthIntrospection.introspect(token) do
        {:ok, claims} ->
          with :ok <- validate_exp_claim(claims, jwt_config[:leeway] || 0) do
            extract_identity_from_claims(claims)
          end

        {:error, _reason} ->
          # Fall back to JWT validation if introspection fails
          decode_and_verify_jwt(token)
      end
    else
      # Use JWT validation
      decode_and_verify_jwt(token)
    end
  end

  defp decode_and_verify_jwt(token) do
    sasl_config = Application.get_env(:elixircd, :sasl, [])
    oauth_config = sasl_config[:oauthbearer] || []
    jwt_config = oauth_config[:jwt] || []

    signer = get_jwt_signer(jwt_config)

    case Joken.verify(token, signer) do
      {:ok, claims} ->
        with :ok <- validate_exp_claim(claims, jwt_config[:leeway] || 0),
             :ok <- validate_expected_claim(claims, "iss", jwt_config[:issuer]),
             :ok <- validate_expected_claim(claims, "aud", jwt_config[:audience]) do
          extract_identity_from_claims(claims)
        end

      {:error, reason} ->
        Logger.debug("JWT verification failed: #{inspect(reason)}")
        {:error, :invalid_token}
    end
  rescue
    e ->
      Logger.error("JWT verification error: #{inspect(e)}")
      {:error, :invalid_token}
  end

  defp get_jwt_signer(jwt_config) do
    algorithm = jwt_config[:algorithm] || "HS256"
    secret = jwt_config[:secret_or_public_key]

    case algorithm do
      "HS256" -> Joken.Signer.create("HS256", secret)
      "HS512" -> Joken.Signer.create("HS512", secret)
      "RS256" -> Joken.Signer.create("RS256", %{"pem" => secret})
      "RS512" -> Joken.Signer.create("RS512", %{"pem" => secret})
      _ -> raise "Unsupported JWT algorithm: #{algorithm}"
    end
  end

  defp extract_identity_from_claims(claims) do
    case Map.get(claims, "sub") do
      nil -> {:error, :invalid_token}
      identity -> {:ok, identity}
    end
  end

  defp validate_exp_claim(claims, leeway_seconds) do
    case Map.get(claims, "exp") do
      nil ->
        :ok

      exp when is_integer(exp) ->
        now = System.system_time(:second)

        if exp + leeway_seconds >= now do
          :ok
        else
          {:error, :token_expired}
        end

      _ ->
        {:error, :invalid_token}
    end
  end

  defp validate_expected_claim(_claims, _key, nil), do: :ok

  defp validate_expected_claim(claims, key, expected) do
    case Map.get(claims, key) do
      ^expected -> :ok
      _ -> {:error, :invalid_token}
    end
  end
end
