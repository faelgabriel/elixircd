defmodule ElixIRCd.Sasl.OAuthIntrospection do
  @moduledoc """
  OAuth 2.0 Token Introspection (RFC 7662).

  Provides functionality to validate OAuth tokens by calling an introspection
  endpoint, which returns information about the token's validity and claims.
  """

  require Logger

  @doc """
  Introspect an OAuth token via configured endpoint.

  Returns `{:ok, claims}` if the token is valid and active, or an error tuple otherwise.
  """
  @spec introspect(String.t()) :: {:ok, map()} | {:error, atom()}
  def introspect(token) do
    sasl_config = Application.get_env(:elixircd, :sasl, [])
    oauth_config = sasl_config[:oauthbearer] || []
    introspection_config = oauth_config[:introspection] || []

    if Keyword.get(introspection_config, :enabled, false) do
      do_introspect(token, introspection_config)
    else
      {:error, :introspection_disabled}
    end
  end

  defp do_introspect(token, config) do
    endpoint = config[:endpoint]
    client_id = config[:client_id]
    client_secret = config[:client_secret]
    timeout = config[:timeout_ms] || 5000

    headers = [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Authorization", "Basic " <> Base.encode64("#{client_id}:#{client_secret}")}
    ]

    body = URI.encode_query(%{"token" => token})

    case HTTPoison.post(endpoint, body, headers, timeout: timeout) do
      {:ok, %{status_code: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"active" => true} = claims} ->
            {:ok, claims}

          {:ok, %{"active" => false}} ->
            {:error, :token_inactive}

          {:error, _} ->
            {:error, :invalid_response}
        end

      {:ok, %{status_code: status}} ->
        Logger.warning("OAuth introspection failed with status #{status}")
        {:error, :introspection_failed}

      {:error, reason} ->
        Logger.error("OAuth introspection request failed: #{inspect(reason)}")
        {:error, :network_error}
    end
  end
end
