defmodule ElixIRCd.Commands.Authenticate.Scram do
  @moduledoc """
  SCRAM (Salted Challenge Response Authentication Mechanism) implementation.

  Supports both SCRAM-SHA-256 and SCRAM-SHA-512 as defined in RFC 5802 and RFC 7677.

  ## Flow:
  1. Client sends client-first-message with username and nonce
  2. Server responds with server-first-message (nonce, salt, iterations)
  3. Client sends client-final-message with proof
  4. Server validates and responds with server-final-message
  """

  require Logger

  @nonce_length 32

  @doc """
  Processes SCRAM authentication step.
  """
  @spec process_step(map(), String.t(), :sha256 | :sha512) ::
          {:continue, String.t(), map()}
          | {:success, String.t(), ElixIRCd.Tables.RegisteredNick.t()}
          | {:error, String.t()}
  def process_step(state, data, hash_algo) do
    case state[:scram_step] do
      nil -> process_client_first(data, hash_algo)
      1 -> process_client_final(state, data, hash_algo)
      _ -> {:error, "Invalid SCRAM state"}
    end
  end

  # Step 1: Process client-first-message
  # Format: n,,n=username,r=client_nonce
  defp process_client_first(data, hash_algo) do
    with {:ok, decoded} <- Base.decode64(data),
         {:ok, parsed} <- parse_client_first(decoded),
         {:ok, credential} <- fetch_scram_credential(parsed.username, hash_algo) do
      client_nonce = parsed.nonce
      server_nonce = generate_nonce()
      full_nonce = client_nonce <> server_nonce
      salt_b64 = Base.encode64(credential.salt)

      server_first = "r=#{full_nonce},s=#{salt_b64},i=#{credential.iterations}"
      server_first_b64 = Base.encode64(server_first)

      state = %{
        scram_step: 1,
        scram_algo: hash_algo,
        username: parsed.username,
        client_nonce: client_nonce,
        server_nonce: server_nonce,
        full_nonce: full_nonce,
        salt: credential.salt,
        iterations: credential.iterations,
        stored_key: credential.stored_key,
        server_key: credential.server_key,
        client_first_bare: parsed.client_first_bare,
        server_first: server_first
      }

      {:continue, server_first_b64, state}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Invalid client-first-message format"}
    end
  end

  # Step 2: Process client-final-message
  # Format: c=biws,r=nonce,p=proof
  defp process_client_final(state, data, hash_algo) do
    with {:ok, decoded} <- Base.decode64(data),
         {:ok, parsed} <- parse_client_final(decoded),
         :ok <- verify_nonce(parsed.nonce, state.full_nonce),
         :ok <- ensure_state_credentials(state),
         {:ok, registered_nick} <- get_registered_nick(state.username),
         :ok <- verify_client_proof(parsed, state, state.stored_key, hash_algo) do
      auth_message =
        build_auth_message(
          state.client_first_bare,
          state.server_first,
          parsed.client_final_without_proof
        )

      server_signature = compute_server_signature(state.server_key, auth_message, hash_algo)
      server_final = "v=#{Base.encode64(server_signature)}"
      server_final_b64 = Base.encode64(server_final)

      {:success, server_final_b64, registered_nick}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "SCRAM authentication failed"}
    end
  end

  defp parse_client_first(message) do
    # Format: n,,n=username,r=nonce
    # or: n,a=authzid,n=username,r=nonce
    parts = String.split(message, ",", parts: 3)

    case parts do
      ["n", _authzid_part, bare_part] ->
        parse_bare_part(bare_part)

      _ ->
        {:error, "Invalid client-first format"}
    end
  end

  defp parse_bare_part(bare_part) do
    bare_parts = String.split(bare_part, ",")

    username =
      Enum.find_value(bare_parts, fn part ->
        case String.split(part, "=", parts: 2) do
          ["n", username] -> sasl_unescape(username)
          _ -> nil
        end
      end)

    nonce =
      Enum.find_value(bare_parts, fn part ->
        case String.split(part, "=", parts: 2) do
          ["r", nonce] -> nonce
          _ -> nil
        end
      end)

    if username && nonce do
      {:ok, %{username: username, nonce: nonce, client_first_bare: bare_part}}
    else
      {:error, "Missing username or nonce"}
    end
  end

  defp parse_client_final(message) do
    # Format: c=biws,r=nonce,p=proof
    parts =
      message
      |> String.split(",")
      |> Enum.map(fn part ->
        case String.split(part, "=", parts: 2) do
          [key, value] -> {key, value}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.into(%{})

    # Find where proof starts to get client-final-without-proof
    proof_index = String.split(message, ",p=") |> hd()

    if parts["c"] && parts["r"] && parts["p"] do
      {:ok,
       %{
         channel_binding: parts["c"],
         nonce: parts["r"],
         proof: Base.decode64!(parts["p"]),
         client_final_without_proof: proof_index
       }}
    else
      {:error, "Missing required fields in client-final"}
    end
  end

  defp verify_nonce(received_nonce, expected_nonce) do
    if received_nonce == expected_nonce do
      :ok
    else
      {:error, "Nonce mismatch"}
    end
  end

  defp get_registered_nick(username) do
    alias ElixIRCd.Repositories.RegisteredNicks

    case RegisteredNicks.get_by_nickname(username) do
      {:ok, registered_nick} -> {:ok, registered_nick}
      {:error, _} -> {:error, "User not found"}
    end
  end

  # Get SCRAM credentials from database
  defp fetch_scram_credential(username, hash_algo) do
    alias ElixIRCd.Repositories.ScramCredentials

    case ScramCredentials.get(username, hash_algo) do
      {:ok, credential} -> {:ok, credential}
      {:error, :not_found} -> {:error, "SCRAM credentials not found. Please re-register or use PLAIN authentication."}
    end
  end

  defp ensure_state_credentials(%{salt: salt, iterations: iterations, stored_key: stored_key, server_key: server_key})
       when is_binary(salt) and is_integer(iterations) and is_binary(stored_key) and is_binary(server_key) do
    :ok
  end

  defp ensure_state_credentials(_state), do: {:error, "SCRAM credentials missing from session state"}

  defp verify_client_proof(parsed, state, stored_key, hash_algo) do
    auth_message =
      build_auth_message(
        state.client_first_bare,
        state.server_first,
        parsed.client_final_without_proof
      )

    hash_func = hash_algo_to_func(hash_algo)

    # Compute ClientSignature = HMAC(StoredKey, AuthMessage)
    client_signature = :crypto.mac(:hmac, hash_func, stored_key, auth_message)

    # Recover ClientKey = ClientProof XOR ClientSignature
    client_proof = parsed.proof

    if byte_size(client_proof) != byte_size(client_signature) do
      {:error, "Invalid proof length"}
    else
      client_key = xor_bytes(client_proof, client_signature)

      # Verify StoredKey = H(ClientKey)
      computed_stored_key = :crypto.hash(hash_func, client_key)

      if computed_stored_key == stored_key do
        :ok
      else
        {:error, "Invalid client proof"}
      end
    end
  end

  @spec xor_bytes(binary(), binary()) :: binary()
  defp xor_bytes(a, b) when byte_size(a) == byte_size(b) do
    a_bytes = :binary.bin_to_list(a)
    b_bytes = :binary.bin_to_list(b)

    a_bytes
    |> Enum.zip(b_bytes)
    |> Enum.map(fn {x, y} -> Bitwise.bxor(x, y) end)
    |> :binary.list_to_bin()
  end

  defp compute_server_signature(server_key, auth_message, hash_algo) do
    hash_func = hash_algo_to_func(hash_algo)
    :crypto.mac(:hmac, hash_func, server_key, auth_message)
  end

  defp build_auth_message(client_first_bare, server_first, client_final_without_proof) do
    "#{client_first_bare},#{server_first},#{client_final_without_proof}"
  end

  defp generate_nonce do
    :crypto.strong_rand_bytes(@nonce_length)
    |> Base.encode64()
    |> String.replace(~r/[^a-zA-Z0-9]/, "")
    |> String.slice(0, @nonce_length)
  end

  defp sasl_unescape(string) do
    string
    |> String.replace("=2C", ",")
    |> String.replace("=3D", "=")
  end

  defp hash_algo_to_func(:sha256), do: :sha256
  defp hash_algo_to_func(:sha512), do: :sha512
end
