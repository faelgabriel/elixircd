defmodule ElixIRCd.Server.S2S.SASL do
  @moduledoc """
  Bounded remote SASL exchange for ENP/1.

  The authority owns credential lookup. This state machine retains only the
  attempt identity, mechanism transcript and an ECDSA challenge; it never
  stores a password, hash, email or private key and it does not create a
  global user until the owner commits the returned binding.
  """

  alias ElixIRCd.Server.S2S.Identity

  @mechanisms ["PLAIN", "ECDSA-NIST256P-CHALLENGE"]
  @max_steps 4
  @max_decoded 65_536

  @type t :: %{
          attempt_id: Identity.id(),
          uid: Identity.id(),
          mechanism: String.t(),
          step: non_neg_integer(),
          client_info: map(),
          challenge: binary() | nil,
          account: String.t() | nil,
          done?: boolean(),
          generation: Identity.id()
        }

  @doc "Starts a pre-registration attempt for a reserved UID."
  @spec start(Identity.id(), Identity.id(), String.t(), map(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def start(uid, attempt_id, mechanism, client_info, options \\ []) do
    cond do
      not Identity.valid_id?(uid) or not Identity.valid_id?(attempt_id) ->
        {:error, :invalid_sasl_identity}

      mechanism not in @mechanisms ->
        {:error, :unsupported_sasl_mechanism}

      not is_map(client_info) ->
        {:error, :invalid_sasl_client_info}

      Keyword.get(options, :max_steps, @max_steps) < 1 ->
        {:error, :invalid_sasl_limit}

      true ->
        {:ok,
         %{
           attempt_id: attempt_id,
           uid: uid,
           mechanism: mechanism,
           step: 0,
           client_info: client_info,
           challenge: nil,
           account: nil,
           done?: false,
           generation: Keyword.get(options, :generation, Identity.nonce())
         }}
    end
  end

  @doc "Processes one already schema-validated Base64 SASL step with defaults."
  @spec step(t(), String.t() | nil) ::
          {:continue, t(), map()} | {:ok, t(), map()} | {:error, term()}
  def step(state, data), do: step(state, data, [])

  @doc "Processes one already schema-validated Base64 SASL step with options."
  @spec step(t(), String.t() | nil, keyword()) ::
          {:continue, t(), map()} | {:ok, t(), map()} | {:error, term()}
  def step(%{done?: true}, _data, _options), do: {:error, :sasl_already_complete}

  def step(%{step: step}, _data, _options) when step >= @max_steps,
    do: {:error, :sasl_step_limit}

  def step(%{mechanism: "PLAIN", step: 0} = state, data, options) do
    with :ok <- secure_plain_client(state.client_info),
         {:ok, decoded} <- decode_data(data),
         {:ok, authzid, username, password} <- plain_fields(decoded),
         {:ok, binding} <- lookup_plain(options, username, password, state.client_info),
         true <- authzid in ["", username] do
      {:ok, %{state | step: 1, done?: true}, %{"uid" => state.uid, "account_id" => binding}}
    else
      false -> {:error, :sasl_authorization_identity_mismatch}
      {:error, _} = error -> error
    end
  end

  def step(%{mechanism: "PLAIN"}, _data, _options), do: {:error, :sasl_extra_step}

  def step(%{mechanism: "ECDSA-NIST256P-CHALLENGE", step: 0} = state, data, _options) do
    with {:ok, account} <- ecdsa_account(data) do
      challenge = :crypto.strong_rand_bytes(32)
      result = %{"challenge" => Base.encode64(challenge), "step" => 1}
      {:continue, %{state | step: 1, challenge: challenge, account: account}, result}
    else
      {:error, _reason} = error -> error
    end
  end

  def step(
        %{mechanism: "ECDSA-NIST256P-CHALLENGE", step: 1, challenge: challenge, account: account} = state,
        data,
        options
      ) do
    with {:ok, signature} <- decode_data(data),
         {:ok, public_key, binding} <- lookup_ecdsa(options, state.uid, account, state.client_info),
         true <- valid_signature?(challenge, signature, public_key) do
      {:ok, %{state | step: 2, done?: true}, %{"uid" => state.uid, "account_id" => binding}}
    else
      false -> {:error, :sasl_signature_invalid}
      {:error, _} = error -> error
    end
  end

  def step(_state, _data, _options), do: {:error, :sasl_invalid_phase}

  @doc "Cancels an attempt and erases its challenge state."
  @spec abort(t()) :: :ok
  def abort(_state), do: :ok

  @doc "Returns the finite mechanisms advertised by the native profile."
  @spec mechanisms() :: [String.t()]
  def mechanisms, do: @mechanisms

  defp secure_plain_client(%{"secure_client" => true}), do: :ok
  defp secure_plain_client(_client_info), do: {:error, :plain_requires_secure_client}

  defp decode_data(nil), do: {:error, :sasl_data_required}

  defp decode_data(data) when is_binary(data) do
    with true <- byte_size(data) <= 131_072,
         {:ok, decoded} <- Base.decode64(data),
         true <- Base.encode64(decoded) == data,
         true <- byte_size(decoded) <= @max_decoded do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_sasl_data}
    end
  end

  defp decode_data(_data), do: {:error, :invalid_sasl_data}

  defp plain_fields(decoded) when is_binary(decoded) do
    case :binary.split(decoded, <<0>>, [:global]) do
      [authzid, username, password] when username != "" ->
        if String.valid?(username) and String.valid?(password),
          do: {:ok, authzid, username, password},
          else: {:error, :invalid_plain_encoding}

      _ ->
        {:error, :invalid_plain_encoding}
    end
  end

  defp lookup_plain(options, username, password, client_info) do
    case Keyword.get(options, :plain_lookup) do
      fun when is_function(fun, 3) ->
        case fun.(username, password, client_info) do
          {:ok, account_id} when is_binary(account_id) ->
            if Identity.valid_id?(account_id), do: {:ok, account_id}, else: {:error, :invalid_credentials}

          :error ->
            {:error, :invalid_credentials}

          _ ->
            {:error, :invalid_credentials}
        end

      _ ->
        {:error, :sasl_authority_unavailable}
    end
  end

  defp lookup_ecdsa(options, uid, account, client_info) do
    case Keyword.get(options, :ecdsa_lookup) do
      fun when is_function(fun, 3) ->
        case fun.(uid, account, client_info) do
          {:ok, public_key, account_id} when is_binary(account_id) ->
            if Identity.valid_id?(account_id),
              do: {:ok, public_key, account_id},
              else: {:error, :invalid_credentials}

          :error ->
            {:error, :invalid_credentials}

          _ ->
            {:error, :invalid_credentials}
        end

      fun when is_function(fun, 2) ->
        case fun.(uid, client_info) do
          {:ok, public_key, account_id} when is_binary(account_id) ->
            if Identity.valid_id?(account_id),
              do: {:ok, public_key, account_id},
              else: {:error, :invalid_credentials}

          :error ->
            {:error, :invalid_credentials}

          _ ->
            {:error, :invalid_credentials}
        end

      _ ->
        {:error, :sasl_authority_unavailable}
    end
  end

  defp ecdsa_account(data) do
    with {:ok, decoded} <- decode_data(data),
         true <- String.valid?(decoded),
         [authcid | authzid_parts] <- :binary.split(decoded, <<0>>, [:global]),
         true <- valid_ecdsa_account_part?(authcid),
         true <- valid_ecdsa_authzid?(authcid, authzid_parts) do
      {:ok, authcid}
    else
      _ -> {:error, :invalid_ecdsa_account}
    end
  end

  defp valid_ecdsa_account_part?(account) do
    account != "" and byte_size(account) <= 64 and
      not Regex.match?(~r/[\x00-\x1f\x7f]/, account)
  end

  defp valid_ecdsa_authzid?(_authcid, []), do: true
  defp valid_ecdsa_authzid?(_authcid, [<<>>]), do: true

  defp valid_ecdsa_authzid?(authcid, [authzid]) do
    valid_ecdsa_account_part?(authzid) and
      ElixIRCd.Utils.CaseMapping.normalize(authcid) == ElixIRCd.Utils.CaseMapping.normalize(authzid)
  end

  defp valid_ecdsa_authzid?(_authcid, _authzid_parts), do: false

  defp valid_signature?(challenge, signature, public_key) when is_binary(signature) do
    try do
      :crypto.verify(:ecdsa, :sha256, {:digest, challenge}, signature, [public_key, :secp256r1])
    rescue
      _ -> false
    end
  end
end
