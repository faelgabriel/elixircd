defmodule ElixIRCd.Sasl.ScramSha256 do
  @moduledoc """
  Implements the cryptographic and wire-format primitives for SCRAM-SHA-256.

  Passwords are converted into a salted verifier containing only the iteration
  count, salt, StoredKey and ServerKey. The verifier is sufficient to
  authenticate a client but cannot be used as the original password.
  """

  @hash :sha256
  @key_length 32
  @minimum_iterations 4096
  @salt_bytes 16
  @nonce_bytes 18

  @type credentials :: %{
          iterations: pos_integer(),
          salt: String.t(),
          stored_key: String.t(),
          server_key: String.t()
        }

  @type server_state :: %{
          account_name: String.t(),
          authenticatable: boolean(),
          client_first_bare: String.t(),
          server_first: String.t(),
          combined_nonce: String.t(),
          channel_binding: String.t(),
          stored_key: binary(),
          server_key: binary()
        }

  @doc "Derives a salted SCRAM verifier from a password."
  @spec derive(String.t(), pos_integer()) :: credentials()
  def derive(password, iterations) when is_binary(password) and iterations >= @minimum_iterations do
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    salted_password = :crypto.pbkdf2_hmac(@hash, password, salt, iterations, @key_length)
    client_key = hmac(salted_password, "Client Key")

    %{
      iterations: iterations,
      salt: Base.encode64(salt),
      stored_key: Base.encode64(:crypto.hash(@hash, client_key)),
      server_key: Base.encode64(hmac(salted_password, "Server Key"))
    }
  end

  @doc "Returns configured SCRAM credentials for a password, when SCRAM is configured."
  @spec configured_credentials(String.t()) :: credentials() | nil
  def configured_credentials(password) do
    case Application.get_env(:elixircd, :sasl, [])[:scram_sha_256] do
      config when is_list(config) -> derive(password, Keyword.fetch!(config, :iterations))
      _ -> nil
    end
  end

  @doc "Starts a server exchange from the decoded client-first message."
  @spec start(String.t(), (String.t() -> {:ok, String.t(), credentials(), boolean()} | :error)) ::
          {:ok, String.t(), server_state()} | {:error, atom()}
  def start(client_first, credential_lookup) when is_binary(client_first) and is_function(credential_lookup, 1) do
    with {:ok, gs2_header, username, client_nonce, client_first_bare} <- parse_client_first(client_first),
         {:ok, account_name, credentials, authenticatable} <- lookup_credentials(username, credential_lookup),
         {:ok, salt, stored_key, server_key, iterations} <- decode_credentials(credentials) do
      combined_nonce = client_nonce <> random_nonce()
      server_first = "r=#{combined_nonce},s=#{Base.encode64(salt)},i=#{iterations}"

      {:ok, server_first,
       %{
         account_name: account_name,
         authenticatable: authenticatable,
         client_first_bare: client_first_bare,
         server_first: server_first,
         combined_nonce: combined_nonce,
         channel_binding: Base.encode64(gs2_header),
         stored_key: stored_key,
         server_key: server_key
       }}
    end
  end

  @doc "Verifies a decoded client-final message and returns the server signature."
  @spec finish(String.t(), server_state()) :: {:ok, String.t()} | {:error, atom()}
  def finish(client_final, state) when is_binary(client_final) and is_map(state) do
    with {:ok, without_proof, attributes, proof} <- parse_client_final(client_final),
         true <- attributes["c"] == state.channel_binding,
         true <- attributes["r"] == state.combined_nonce,
         true <- state.authenticatable,
         auth_message = state.client_first_bare <> "," <> state.server_first <> "," <> without_proof,
         client_signature = hmac(state.stored_key, auth_message),
         true <- byte_size(proof) == byte_size(client_signature),
         client_key = xor_binaries(proof, client_signature),
         candidate_stored_key = :crypto.hash(@hash, client_key),
         true <- Plug.Crypto.secure_compare(candidate_stored_key, state.stored_key) do
      server_signature = hmac(state.server_key, auth_message)
      {:ok, "v=" <> Base.encode64(server_signature)}
    else
      _ -> {:error, :invalid_client_final}
    end
  end

  @spec parse_client_first(String.t()) ::
          {:ok, String.t(), String.t(), String.t(), String.t()} | {:error, atom()}
  defp parse_client_first(message) do
    case :binary.split(message, ",", [:global]) do
      [flag, authzid | bare_parts] when flag in ["n", "y"] and bare_parts != [] ->
        gs2_header = flag <> "," <> authzid <> ","
        client_first_bare = Enum.join(bare_parts, ",")

        with :ok <- validate_authzid(authzid),
             {:ok, attributes} <- parse_attributes(client_first_bare),
             {:ok, escaped_username} <- fetch_attribute(attributes, "n"),
             {:ok, username} <- unescape_name(escaped_username),
             {:ok, nonce} <- fetch_attribute(attributes, "r"),
             true <- username != "" and valid_nonce?(nonce) do
          {:ok, gs2_header, username, nonce, client_first_bare}
        else
          _ -> {:error, :invalid_client_first}
        end

      _ ->
        {:error, :invalid_client_first}
    end
  end

  @spec validate_authzid(String.t()) :: :ok | {:error, atom()}
  defp validate_authzid(""), do: :ok
  defp validate_authzid(_authzid), do: {:error, :authorization_identity_not_supported}

  @spec lookup_credentials(String.t(), function()) ::
          {:ok, String.t(), credentials(), boolean()} | {:error, atom()}
  defp lookup_credentials(username, lookup) do
    case lookup.(username) do
      {:ok, account_name, credentials, authenticatable}
      when is_binary(account_name) and is_map(credentials) and is_boolean(authenticatable) ->
        {:ok, account_name, credentials, authenticatable}

      :error ->
        {:error, :credentials_not_found}

      _ ->
        {:error, :invalid_credentials}
    end
  end

  @spec decode_credentials(credentials()) :: {:ok, binary(), binary(), binary(), pos_integer()} | {:error, atom()}
  defp decode_credentials(credentials) do
    with iterations when is_integer(iterations) and iterations >= @minimum_iterations <- credentials[:iterations],
         {:ok, salt} <- Base.decode64(credentials[:salt] || ""),
         {:ok, stored_key} <- Base.decode64(credentials[:stored_key] || ""),
         {:ok, server_key} <- Base.decode64(credentials[:server_key] || ""),
         true <- byte_size(salt) >= 8,
         true <- byte_size(stored_key) == @key_length,
         true <- byte_size(server_key) == @key_length do
      {:ok, salt, stored_key, server_key, iterations}
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  @spec parse_client_final(String.t()) :: {:ok, String.t(), map(), binary()} | {:error, atom()}
  defp parse_client_final(message) do
    parts = :binary.split(message, ",", [:global])

    with [proof_part | reversed_without_proof] <- Enum.reverse(parts),
         "p=" <> encoded_proof <- proof_part,
         without_proof_parts when without_proof_parts != [] <- Enum.reverse(reversed_without_proof),
         without_proof = Enum.join(without_proof_parts, ","),
         {:ok, attributes} <- parse_attributes(without_proof),
         true <- Map.has_key?(attributes, "c") and Map.has_key?(attributes, "r"),
         {:ok, proof} <- Base.decode64(encoded_proof) do
      {:ok, without_proof, attributes, proof}
    else
      _ -> {:error, :invalid_client_final}
    end
  end

  @spec parse_attributes(String.t()) :: {:ok, map()} | {:error, atom()}
  defp parse_attributes(message) do
    message
    |> :binary.split(",", [:global])
    |> Enum.reduce_while({:ok, %{}}, fn part, {:ok, attributes} ->
      case :binary.split(part, "=") do
        [<<key>>, value] when key not in [?m, ?,] and not is_map_key(attributes, <<key>>) ->
          {:cont, {:ok, Map.put(attributes, <<key>>, value)}}

        _ ->
          {:halt, {:error, :invalid_attribute}}
      end
    end)
  end

  @spec fetch_attribute(map(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  defp fetch_attribute(attributes, key) do
    case Map.fetch(attributes, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :missing_attribute}
    end
  end

  @spec unescape_name(String.t()) :: {:ok, String.t()} | {:error, atom()}
  defp unescape_name(name), do: unescape_name(name, "")

  defp unescape_name("", result), do: {:ok, result}
  defp unescape_name("=2C" <> rest, result), do: unescape_name(rest, result <> ",")
  defp unescape_name("=3D" <> rest, result), do: unescape_name(rest, result <> "=")
  defp unescape_name("=" <> _rest, _result), do: {:error, :invalid_escape}
  defp unescape_name(<<character::utf8, rest::binary>>, result), do: unescape_name(rest, result <> <<character::utf8>>)
  defp unescape_name(_invalid_utf8, _result), do: {:error, :invalid_username}

  @spec valid_nonce?(String.t()) :: boolean()
  defp valid_nonce?(nonce) do
    nonce != "" and Enum.all?(:binary.bin_to_list(nonce), &(&1 >= 0x21 and &1 <= 0x7E and &1 != ?,))
  end

  @spec random_nonce() :: String.t()
  defp random_nonce, do: @nonce_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @spec hmac(binary(), iodata()) :: binary()
  defp hmac(key, data), do: :crypto.mac(:hmac, @hash, key, data)

  @spec xor_binaries(binary(), binary()) :: binary()
  defp xor_binaries(left, right), do: :crypto.exor(left, right)
end
