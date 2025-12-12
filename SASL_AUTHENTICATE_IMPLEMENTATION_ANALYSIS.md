# Análise da Implementação SASL AUTHENTICATE - ElixIRCd

**Data de Análise:** 2025-12-07
**Mecanismos SASL Implementados:** PLAIN, SCRAM-SHA-256, SCRAM-SHA-512, EXTERNAL, OAUTHBEARER

---

## Sumário Executivo

Esta análise documenta o estado atual da implementação SASL AUTHENTICATE no ElixIRCd, identificando problemas existentes, TODOs pendentes, e integrações necessárias com o sistema NickServ existente. A implementação segue a especificação IRCv3 SASL 3.1/3.2.

---

## 1. ANÁLISE DA CONFIGURAÇÃO

### 1.1. ❌ **PROBLEMA: Configuração SASL Incompleta**

**Arquivo:** `config/elixircd.exs` (linhas 143-173)

**Problema Identificado:**
- A configuração SASL existe mas não está sendo utilizada corretamente pelos mecanismos
- Falta configuração para mecanismos PLAIN e SCRAM
- Configuração do OAUTHBEARER está presente mas não é verificada no código

**Configuração Atual:**
```elixir
sasl: [
  # EXTERNAL mechanism configuration
  external: [
    enabled: false,
    ca_cert_file: nil
  ],
  # OAUTHBEARER mechanism configuration
  oauthbearer: [
    enabled: false,
    jwt: [
      issuer: nil,
      audience: nil,
      algorithm: "HS256",
      secret_or_public_key: nil
    ],
    introspection: [
      enabled: false,
      endpoint: nil,
      client_id: nil,
      client_secret: nil
    ]
  ]
]
```

**O que precisa adicionar:**
```elixir
sasl: [
  # PLAIN mechanism configuration
  plain: [
    enabled: true,
    # Require TLS for PLAIN authentication
    require_tls: true
  ],

  # SCRAM mechanisms configuration
  scram: [
    enabled: true,
    # Store SCRAM credentials separately from Argon2
    store_scram_credentials: false,  # TODO: implement proper SCRAM storage
    iterations: 4096,
    # Supported hash algorithms
    algorithms: ["SHA-256", "SHA-512"]
  ],

  # EXTERNAL mechanism configuration
  external: [
    enabled: false,
    # Require client certificates
    require_client_cert: true,
    # Path to trusted CA certificates for client cert validation
    ca_cert_file: nil,
    # Certificate fingerprint mapping to accounts
    # Format: %{"fingerprint" => "nickname"}
    cert_mappings: %{}
  ],

  # OAUTHBEARER mechanism configuration
  oauthbearer: [
    enabled: false,
    # Require TLS for OAuth
    require_tls: true,
    jwt: [
      issuer: nil,
      audience: nil,
      algorithm: "HS256",
      secret_or_public_key: nil,
      # Allow clock skew in seconds
      leeway: 60
    ],
    introspection: [
      enabled: false,
      endpoint: nil,
      client_id: nil,
      client_secret: nil,
      # Timeout for introspection requests
      timeout_ms: 5000
    ]
  ],

  # General SASL settings
  session_timeout_ms: 60_000,  # Timeout for incomplete SASL sessions
  max_attempts_per_connection: 3,  # Maximum failed authentication attempts
  rate_limit: [
    enabled: true,
    max_attempts: 5,
    window_ms: 300_000  # 5 minutes
  ]
]
```

---

## 2. ANÁLISE DO CAP (Capability Negotiation)

### 2.1. ⚠️ **PROBLEMA: Lista de Mecanismos não é anunciada no CAP LS**

**Arquivo:** `lib/elixircd/commands/cap.ex` (linha 144)

**Problema:**
```elixir
{:sasl, "SASL"},
```

**Conforme IRCv3 SASL 3.2, deveria ser:**
```elixir
{:sasl, build_sasl_capability_value()},
```

**Nova função necessária:**
```elixir
@spec build_sasl_capability_value() :: String.t()
defp build_sasl_capability_value do
  sasl_config = Application.get_env(:elixircd, :sasl, [])

  # Get enabled mechanisms based on configuration
  mechanisms = []

  # Add PLAIN if enabled
  mechanisms = if Keyword.get(sasl_config[:plain] || [], :enabled, true) do
    ["PLAIN" | mechanisms]
  else
    mechanisms
  end

  # Add SCRAM mechanisms if enabled
  mechanisms = if Keyword.get(sasl_config[:scram] || [], :enabled, true) do
    ["SCRAM-SHA-256", "SCRAM-SHA-512" | mechanisms]
  else
    mechanisms
  end

  # Add EXTERNAL if enabled
  mechanisms = if Keyword.get(sasl_config[:external] || [], :enabled, false) do
    ["EXTERNAL" | mechanisms]
  else
    mechanisms
  end

  # Add OAUTHBEARER if enabled
  mechanisms = if Keyword.get(sasl_config[:oauthbearer] || [], :enabled, false) do
    ["OAUTHBEARER" | mechanisms]
  else
    mechanisms
  end

  # Return "SASL=MECH1,MECH2,..." format
  if mechanisms == [] do
    "SASL"
  else
    mechanisms_str = mechanisms |> Enum.reverse() |> Enum.join(",")
    "SASL=#{mechanisms_str}"
  end
end
```

---

## 3. ANÁLISE DO COMANDO AUTHENTICATE

### 3.1. ✅ **BOM: Estrutura Geral Correta**

**Arquivo:** `lib/elixircd/commands/authenticate.ex`

**Pontos Positivos:**
- Implementa o fluxo base do SASL corretamente
- Suporta fragmentação de mensagens (chunking)
- Implementa abort com `*`
- Valida comprimento máximo de 400 bytes
- Limpa sessões após autenticação

### 3.2. ❌ **PROBLEMA CRÍTICO: Não verifica se CAP sasl foi negociado**

**Localização:** `lib/elixircd/commands/authenticate.ex` (linha 72)

**Problema:**
O comando AUTHENTICATE deve ser rejeitado se o cliente não negociou a capability `sasl` primeiro.

**Código Atual:**
```elixir
def handle(user, %{command: "AUTHENTICATE", params: [mechanism | _]}) do
  handle_authenticate(user, mechanism)
end
```

**Correção Necessária:**
```elixir
def handle(user, %{command: "AUTHENTICATE", params: [mechanism | _]}) do
  if "SASL" in user.capabilities do
    handle_authenticate(user, mechanism)
  else
    %Message{
      command: :err_unknowncommand,
      params: [user_reply(user), "AUTHENTICATE"],
      trailing: "You must negotiate SASL capability first"
    }
    |> Dispatcher.broadcast(:server, user)
  end
end
```

### 3.3. ⚠️ **PROBLEMA: Não verifica configuração individual de mecanismos**

**Localização:** `lib/elixircd/commands/authenticate.ex` (linha 96-124)

**Problema:**
A função `handle_mechanism_selection/2` apenas verifica se o SASL está habilitado globalmente, mas não verifica se o mecanismo específico está habilitado na configuração.

**Código Atual:**
```elixir
defp handle_mechanism_selection(user, mechanism) do
  normalized_mechanism = String.upcase(mechanism)

  cond do
    not sasl_enabled?() ->
      # ...
    normalized_mechanism not in @supported_mechanisms ->
      # ...
    true ->
      start_sasl_session(user, normalized_mechanism)
  end
end
```

**Correção Necessária:**
```elixir
defp handle_mechanism_selection(user, mechanism) do
  normalized_mechanism = String.upcase(mechanism)

  cond do
    not sasl_enabled?() ->
      send_sasl_disabled_error(user)

    normalized_mechanism not in @supported_mechanisms ->
      send_available_mechanisms(user)
      send_mechanism_not_supported_error(user)

    not mechanism_enabled?(normalized_mechanism) ->
      send_available_mechanisms(user)
      %Message{
        command: :err_saslfail,
        params: [user_reply(user)],
        trailing: "SASL mechanism is disabled by server configuration"
      }
      |> Dispatcher.broadcast(:server, user)

    true ->
      start_sasl_session(user, normalized_mechanism)
  end
end

@spec mechanism_enabled?(String.t()) :: boolean()
defp mechanism_enabled?(mechanism) do
  sasl_config = Application.get_env(:elixircd, :sasl, [])

  case mechanism do
    "PLAIN" ->
      Keyword.get(sasl_config[:plain] || [], :enabled, true)

    "SCRAM-SHA-256" ->
      scram_config = sasl_config[:scram] || []
      Keyword.get(scram_config, :enabled, true) and
        "SHA-256" in Keyword.get(scram_config, :algorithms, ["SHA-256", "SHA-512"])

    "SCRAM-SHA-512" ->
      scram_config = sasl_config[:scram] || []
      Keyword.get(scram_config, :enabled, true) and
        "SHA-512" in Keyword.get(scram_config, :algorithms, ["SHA-256", "SHA-512"])

    "EXTERNAL" ->
      Keyword.get(sasl_config[:external] || [], :enabled, false)

    "OAUTHBEARER" ->
      Keyword.get(sasl_config[:oauthbearer] || [], :enabled, false)

    _ ->
      false
  end
end
```

### 3.4. ❌ **PROBLEMA: Falta verificação de TLS para PLAIN**

**Localização:** `lib/elixircd/commands/authenticate.ex` (linha 189-209)

**Problema:**
O mecanismo PLAIN envia senha em texto claro (apenas Base64), deveria exigir TLS quando configurado.

**Código a adicionar antes de `process_plain_auth/2`:**
```elixir
@spec process_plain_auth(User.t(), ElixIRCd.Tables.SaslSession.t()) :: :ok
defp process_plain_auth(user, session) do
  sasl_config = Application.get_env(:elixircd, :sasl, [])
  require_tls = Keyword.get(sasl_config[:plain] || [], :require_tls, true)

  if require_tls and user.transport not in [:tls, :wss] do
    %Message{
      command: :err_saslfail,
      params: [user_reply(user)],
      trailing: "PLAIN mechanism requires TLS connection"
    }
    |> Dispatcher.broadcast(:server, user)

    SaslSessions.delete(user.pid)
  else
    do_process_plain_auth(user, session)
  end
end

@spec do_process_plain_auth(User.t(), ElixIRCd.Tables.SaslSession.t()) :: :ok
defp do_process_plain_auth(user, session) do
  # código atual aqui
  case decode_plain_credentials(session.buffer) do
    # ...
  end
end
```

### 3.5. ⚠️ **PROBLEMA: Falta timeout para sessões SASL**

**Problema:**
Sessões SASL podem ficar abertas indefinidamente se o cliente não completar a autenticação.

**Solução:**
Criar um GenServer para gerenciar timeouts de sessões SASL.

**Novo arquivo:** `lib/elixircd/sasl/session_monitor.ex`
```elixir
defmodule ElixIRCd.Sasl.SessionMonitor do
  @moduledoc """
  Monitors SASL authentication sessions and cleans up expired ones.
  """

  use GenServer
  require Logger

  alias ElixIRCd.Repositories.SaslSessions
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Message

  @check_interval 30_000  # Check every 30 seconds

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    schedule_check()
    {:ok, state}
  end

  @impl true
  def handle_info(:check_timeouts, state) do
    check_and_cleanup_expired_sessions()
    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    Process.send_after(self(), :check_timeouts, @check_interval)
  end

  defp check_and_cleanup_expired_sessions do
    timeout_ms = Application.get_env(:elixircd, :sasl)[:session_timeout_ms] || 60_000
    cutoff_time = DateTime.add(DateTime.utc_now(), -timeout_ms, :millisecond)

    Memento.transaction!(fn ->
      ElixIRCd.Tables.SaslSession
      |> Memento.Query.all()
      |> Enum.filter(fn session ->
        DateTime.compare(session.created_at, cutoff_time) == :lt
      end)
      |> Enum.each(fn session ->
        Logger.debug("SASL session timeout for user PID #{inspect(session.user_pid)}")

        case Users.get(session.user_pid) do
          {:ok, user} ->
            %Message{
              command: :err_saslaborted,
              params: [user.nick || "*"],
              trailing: "SASL authentication timeout"
            }
            |> Dispatcher.broadcast(:server, user)

          _ ->
            :ok
        end

        SaslSessions.delete(session.user_pid)
      end)
    end)
  end
end
```

**Adicionar ao supervisor em:** `lib/elixircd/application.ex`
```elixir
children = [
  # ... existing children
  ElixIRCd.Sasl.SessionMonitor,
  # ...
]
```

### 3.6. ⚠️ **PROBLEMA: Falta rate limiting para tentativas de autenticação**

**Problema:**
Não há limite de tentativas de autenticação por conexão, permitindo brute force.

**Solução:**
Adicionar contador de tentativas na tabela User e validar antes de processar autenticação.

**Alteração necessária em:** `lib/elixircd/tables/user.ex`
```elixir
# Adicionar campo:
:sasl_attempts,

@type t :: %__MODULE__{
  # ... existing fields
  sasl_attempts: non_neg_integer() | nil,
  # ...
}
```

**Adicionar validação em:** `lib/elixircd/commands/authenticate.ex`
```elixir
defp handle_mechanism_selection(user, mechanism) do
  max_attempts = Application.get_env(:elixircd, :sasl)[:max_attempts_per_connection] || 3
  current_attempts = user.sasl_attempts || 0

  if current_attempts >= max_attempts do
    %Message{
      command: :err_saslfail,
      params: [user_reply(user)],
      trailing: "Too many SASL authentication attempts"
    }
    |> Dispatcher.broadcast(:server, user)

    # Optionally disconnect the user
    {:quit, "Too many SASL authentication attempts"}
  else
    # Continue with normal flow
    # ...
  end
end
```

---

## 4. ANÁLISE DO MECANISMO PLAIN

### 4.1. ✅ **BOM: Implementação funcional**

**Arquivo:** `lib/elixircd/commands/authenticate.ex` (linhas 189-209)

**Pontos Positivos:**
- Decodifica corretamente o formato `authzid\0authcid\0password`
- Valida campos obrigatórios
- Usa Argon2 para verificação (compatível com NickServ)

### 4.2. ⚠️ **MELHORIA: Adicionar suporte a authzid**

**Problema:**
O código atual ignora authzid, mas deveria validá-lo quando fornecido.

**Código Atual (linha 192-195):**
```elixir
{:ok, {authzid, authcid, password}} ->
  # authzid is usually empty, authcid is the username
  username = if authcid != "", do: authcid, else: authzid
  authenticate_user(user, username, password)
```

**Melhoria:**
```elixir
{:ok, {authzid, authcid, password}} ->
  # RFC 4616: authzid is the identity to act as (authorization identity)
  # authcid is the identity to authenticate as (authentication identity)

  cond do
    authcid == "" and authzid == "" ->
      {:error, "Both authcid and authzid cannot be empty"}

    authcid != "" and authzid != "" and authcid != authzid ->
      # Client wants to authenticate as authcid but act as authzid
      # This requires additional permission checking
      authenticate_user_with_authz(user, authcid, authzid, password)

    true ->
      # Normal case: authenticate as authcid (or authzid if authcid empty)
      username = if authcid != "", do: authcid, else: authzid
      authenticate_user(user, username, password)
  end
```

---

## 5. ANÁLISE DO MECANISMO SCRAM

### 5.1. ❌ **PROBLEMA CRÍTICO: Armazenamento de credenciais incompatível**

**Arquivo:** `lib/elixircd/commands/authenticate/scram.ex` (linhas 184-201)

**Problema Grave:**
O SCRAM requer armazenar `SaltedPassword`, `StoredKey` e `ServerKey` no banco de dados, mas atualmente o sistema usa Argon2 hash do NickServ. A implementação atual tenta derivar chaves do hash Argon2, o que é **incorreto e inseguro**.

**Código Atual (INCORRETO):**
```elixir
defp derive_keys_from_hash(password_hash, _salt, _iterations, hash_algo) do
  # In a production system, you'd want to store SCRAM-specific data
  # For this implementation, we'll derive from the password hash
  hash_func = hash_algo_to_func(hash_algo)

  # Use the password hash as the salted password
  salted_password = :crypto.hash(hash_func, password_hash)

  # Derive client and server keys
  client_key = :crypto.mac(:hmac, hash_func, salted_password, "Client Key")
  stored_key = :crypto.hash(hash_func, client_key)
  server_key = :crypto.mac(:hmac, hash_func, salted_password, "Server Key")

  {:ok, stored_key, server_key}
end
```

**Solução Necessária:**

#### 5.1.1. Adicionar tabela para credenciais SCRAM

**Novo arquivo:** `lib/elixircd/tables/scram_credential.ex`
```elixir
defmodule ElixIRCd.Tables.ScramCredential do
  @moduledoc """
  Stores SCRAM authentication credentials.

  When a user registers or changes their password, we store SCRAM credentials
  separately to enable SCRAM authentication while maintaining Argon2 for IDENTIFY.
  """

  use Memento.Table,
    attributes: [
      :nickname_key,    # Primary key (normalized nickname)
      :algorithm,       # :sha256 or :sha512
      :iterations,      # Number of iterations
      :salt,            # Random salt (binary)
      :stored_key,      # H(ClientKey) (binary)
      :server_key,      # ServerKey (binary)
      :created_at,
      :updated_at
    ],
    index: [:algorithm],
    type: :set

  @type t :: %__MODULE__{
          nickname_key: String.t(),
          algorithm: :sha256 | :sha512,
          iterations: pos_integer(),
          salt: binary(),
          stored_key: binary(),
          server_key: binary(),
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @type t_attrs :: %{
          optional(:nickname_key) => String.t(),
          optional(:algorithm) => :sha256 | :sha512,
          optional(:iterations) => pos_integer(),
          optional(:salt) => binary(),
          optional(:stored_key) => binary(),
          optional(:server_key) => binary(),
          optional(:created_at) => DateTime.t(),
          optional(:updated_at) => DateTime.t()
        }

  @doc """
  Create new SCRAM credential entry.
  """
  @spec new(t_attrs()) :: t()
  def new(attrs) do
    now = DateTime.utc_now()

    new_attrs =
      attrs
      |> Map.put_new(:created_at, now)
      |> Map.put_new(:updated_at, now)

    struct!(__MODULE__, new_attrs)
  end

  @doc """
  Generate SCRAM credentials from plaintext password.
  """
  @spec generate_from_password(String.t(), String.t(), :sha256 | :sha512, pos_integer()) :: t()
  def generate_from_password(nickname, password, algorithm, iterations) do
    alias ElixIRCd.Utils.CaseMapping

    nickname_key = CaseMapping.normalize(nickname)
    hash_func = if algorithm == :sha256, do: :sha256, else: :sha512

    # Generate random salt
    salt = :crypto.strong_rand_bytes(16)

    # Normalize password (SASLprep should be applied here in production)
    normalized_password = password

    # Compute SaltedPassword using PBKDF2
    salted_password = :crypto.pbkdf2_hmac(
      hash_func,
      normalized_password,
      salt,
      iterations,
      if(algorithm == :sha256, do: 32, else: 64)
    )

    # Compute ClientKey and ServerKey
    client_key = :crypto.mac(:hmac, hash_func, salted_password, "Client Key")
    stored_key = :crypto.hash(hash_func, client_key)
    server_key = :crypto.mac(:hmac, hash_func, salted_password, "Server Key")

    new(%{
      nickname_key: nickname_key,
      algorithm: algorithm,
      iterations: iterations,
      salt: salt,
      stored_key: stored_key,
      server_key: server_key
    })
  end
end
```

#### 5.1.2. Adicionar repositório para credenciais SCRAM

**Novo arquivo:** `lib/elixircd/repositories/scram_credentials.ex`
```elixir
defmodule ElixIRCd.Repositories.ScramCredentials do
  @moduledoc """
  Repository for SCRAM credentials.
  """

  alias ElixIRCd.Tables.ScramCredential
  alias ElixIRCd.Utils.CaseMapping

  @doc """
  Get SCRAM credentials for a nickname and algorithm.
  """
  @spec get(String.t(), :sha256 | :sha512) :: {:ok, ScramCredential.t()} | {:error, :not_found}
  def get(nickname, algorithm) do
    nickname_key = CaseMapping.normalize(nickname)

    # SCRAM credentials use composite key: nickname_key + algorithm
    # We need to scan for matching records
    Memento.transaction!(fn ->
      ScramCredential
      |> Memento.Query.all()
      |> Enum.find(fn cred ->
        cred.nickname_key == nickname_key and cred.algorithm == algorithm
      end)
      |> case do
        nil -> {:error, :not_found}
        credential -> {:ok, credential}
      end
    end)
  end

  @doc """
  Create or update SCRAM credentials for a nickname.
  """
  @spec upsert(ScramCredential.t()) :: ScramCredential.t()
  def upsert(credential) do
    Memento.transaction!(fn ->
      # Delete existing credential for this nickname+algorithm
      case get(credential.nickname_key, credential.algorithm) do
        {:ok, existing} ->
          Memento.Query.delete_record(existing)
        _ ->
          :ok
      end

      # Write new credential
      Memento.Query.write(credential)
    end)

    credential
  end

  @doc """
  Delete all SCRAM credentials for a nickname.
  """
  @spec delete_all(String.t()) :: :ok
  def delete_all(nickname) do
    nickname_key = CaseMapping.normalize(nickname)

    Memento.transaction!(fn ->
      ScramCredential
      |> Memento.Query.all()
      |> Enum.filter(fn cred -> cred.nickname_key == nickname_key end)
      |> Enum.each(&Memento.Query.delete_record/1)
    end)

    :ok
  end

  @doc """
  Generate and store SCRAM credentials for a nickname.
  """
  @spec generate_and_store(String.t(), String.t()) :: :ok
  def generate_and_store(nickname, password) do
    iterations = Application.get_env(:elixircd, :sasl)[:scram][:iterations] || 4096

    # Generate for both SHA-256 and SHA-512
    [:sha256, :sha512]
    |> Enum.each(fn algorithm ->
      credential = ScramCredential.generate_from_password(
        nickname,
        password,
        algorithm,
        iterations
      )

      upsert(credential)
    end)

    :ok
  end
end
```

#### 5.1.3. Atualizar NickServ REGISTER para gerar credenciais SCRAM

**Arquivo:** `lib/elixircd/services/nickserv/register.ex`

**Adicionar após criar o registered_nick:**
```elixir
# Generate SCRAM credentials for SASL authentication
if Application.get_env(:elixircd, :sasl)[:scram][:enabled] do
  ElixIRCd.Repositories.ScramCredentials.generate_and_store(nickname, password)
end
```

#### 5.1.4. Corrigir implementação do SCRAM

**Arquivo:** `lib/elixircd/commands/authenticate/scram.ex`

**Substituir função `derive_keys_from_hash` por:**
```elixir
defp get_scram_credentials(username, hash_algo) do
  alias ElixIRCd.Repositories.ScramCredentials

  case ScramCredentials.get(username, hash_algo) do
    {:ok, credential} ->
      {:ok, credential.salt, credential.iterations, credential.stored_key, credential.server_key}

    {:error, :not_found} ->
      {:error, "SCRAM credentials not found. Please re-register or use PLAIN authentication."}
  end
end
```

**Atualizar `process_client_final`:**
```elixir
defp process_client_final(state, data, hash_algo) do
  with {:ok, decoded} <- Base.decode64(data),
       {:ok, parsed} <- parse_client_final(decoded),
       :ok <- verify_nonce(parsed.nonce, state.full_nonce),
       {:ok, registered_nick} <- get_registered_nick(state.username),
       {:ok, salt, iterations, stored_key, server_key} <-
         get_scram_credentials(state.username, hash_algo),
       :ok <- verify_scram_data_matches(salt, iterations, state.salt, state.iterations),
       :ok <- verify_client_proof(parsed, state, stored_key, hash_algo) do
    # ... rest of the function
  end
end

defp verify_scram_data_matches(db_salt, db_iterations, session_salt, session_iterations) do
  if db_salt == session_salt and db_iterations == session_iterations do
    :ok
  else
    {:error, "SCRAM data mismatch"}
  end
end
```

### 5.2. ❌ **PROBLEMA: Verificação de client proof não está implementada**

**Arquivo:** `lib/elixircd/commands/authenticate/scram.ex` (linhas 202-216)

**Código Atual (STUB):**
```elixir
defp verify_client_proof(parsed, state, stored_key, hash_algo) do
  auth_message = build_auth_message(state.client_first_bare, state.server_first, parsed.client_final_without_proof)
  hash_func = hash_algo_to_func(hash_algo)

  _client_signature = :crypto.mac(:hmac, hash_func, stored_key, auth_message)

  # Client proof is XOR of client_key and client_signature
  # We need to verify: client_proof XOR client_signature == client_key
  # Then hash(client_key) == stored_key

  # For simplicity in this implementation, we'll do a basic verification
  # In production, you'd want the full XOR verification
  :ok
end
```

**Implementação Correta:**
```elixir
defp verify_client_proof(parsed, state, stored_key, hash_algo) do
  auth_message = build_auth_message(
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
```

### 5.3. ⚠️ **MELHORIA: Implementar SASLprep para normalização de senha**

**Problema:**
RFC 4013 define SASLprep para normalização de senhas SCRAM, que deve ser aplicado antes de computar as chaves.

**Solução:**
Adicionar biblioteca `stringprep` ou implementar subset básico.

**Para agora (workaround):**
Documentar limitação e adicionar validação básica:

```elixir
defp normalize_password(password) do
  # TODO: Implement full SASLprep (RFC 4013)
  # For now, basic validation:
  # - No control characters
  # - Valid UTF-8

  cond do
    not String.valid?(password) ->
      {:error, "Password must be valid UTF-8"}

    String.match?(password, ~r/[\x00-\x1F\x7F]/) ->
      {:error, "Password contains invalid control characters"}

    true ->
      {:ok, password}
  end
end
```

### 5.4. ⚠️ **FALTA: Esperando AUTHENTICATE + final**

**Problema:**
Conforme RFC e documentação fornecida, após enviar server-final-message, o servidor deve esperar um `AUTHENTICATE +` vazio do cliente antes de enviar 900/903.

**Localização:** `lib/elixircd/commands/authenticate.ex` (linha 226-232)

**Código Atual:**
```elixir
{:success, response, registered_nick} ->
  # Send final response
  %Message{command: "AUTHENTICATE", params: [response]}
  |> Dispatcher.broadcast(:server, user)

  # Complete authentication
  complete_scram_authentication(user, registered_nick)
```

**Correção:**
```elixir
{:success, response, registered_nick} ->
  # Send final response
  %Message{command: "AUTHENTICATE", params: [response]}
  |> Dispatcher.broadcast(:server, user)

  # Update session to wait for final +
  SaslSessions.update(session, %{
    state: Map.put(session.state || %{}, :scram_step, 2),
    buffer: "",
    pending_completion: registered_nick
  })

{:complete, registered_nick} ->
  # Client sent final +, now complete authentication
  complete_scram_authentication(user, registered_nick)
```

**Atualizar process_scram_auth:**
```elixir
defp process_scram_auth(user, session, hash_algo) do
  state = session.state || %{}

  # Check if we're waiting for final +
  if state[:scram_step] == 2 do
    if session.buffer == "" or session.buffer == "+" do
      # Final + received
      complete_scram_authentication(user, session.pending_completion)
    else
      # Unexpected data
      send_sasl_fail(user, "Expected empty response")
      SaslSessions.delete(user.pid)
    end
  else
    # Normal SCRAM processing
    result = Scram.process_step(state, session.buffer, hash_algo)
    # ... rest of existing code
  end
end
```

---

## 6. ANÁLISE DO MECANISMO EXTERNAL

### 6.1. ❌ **PROBLEMA: Não implementado - apenas stub**

**Arquivo:** `lib/elixircd/commands/authenticate/external.ex`

**Problema:**
A implementação atual sempre retorna erro. Falta:
1. Extração de certificado TLS da conexão
2. Validação da cadeia de certificados
3. Extração de CN ou SAN
4. Mapeamento de fingerprint para conta

**Tarefas Necessárias:**

#### 6.1.1. Adicionar suporte a peer certificate no transport

**Localização:** Depende da implementação do transport layer (Ranch)

**Adicionar ao User.t():**
```elixir
@type t :: %__MODULE__{
  # ... existing fields
  tls_peer_cert: binary() | nil,
  tls_cert_verified: boolean() | nil,
  # ...
}
```

#### 6.1.2. Implementar extração de identidade do certificado

**Arquivo:** `lib/elixircd/commands/authenticate/external.ex`

**Substituir stub por implementação real:**
```elixir
defp extract_certificate_identity(user) do
  cert_binary = user.tls_peer_cert

  if cert_binary == nil do
    {:error, "No client certificate provided"}
  else
    case :public_key.pkix_decode_cert(cert_binary, :otp) do
      {:OTPCertificate, _tbs, _algo, _sig} = otp_cert ->
        extract_identity_from_otp_cert(otp_cert)

      _ ->
        {:error, "Failed to decode certificate"}
    end
  end
end

defp extract_identity_from_otp_cert(otp_cert) do
  # Extract Subject CN
  {:OTPCertificate, tbs_cert, _algo, _sig} = otp_cert
  {:OTPTBSCertificate, _version, _serial, _sig_algo, _issuer, _validity, subject, _pk, _issuer_id, _subject_id, extensions} = tbs_cert

  # Get CN from subject
  cn = extract_cn_from_subject(subject)

  # Get SAN from extensions
  san_list = extract_san_from_extensions(extensions)

  # Prefer SAN over CN
  identity = Enum.at(san_list, 0) || cn

  if identity do
    verify_identity(identity, otp_cert)
  else
    {:error, "No identity found in certificate"}
  end
end

defp extract_cn_from_subject({:rdnSequence, rdn_list}) do
  rdn_list
  |> List.flatten()
  |> Enum.find_value(fn attr_type_value ->
    case attr_type_value do
      {:AttributeTypeAndValue, {2, 5, 4, 3}, cn} ->
        # CN OID is 2.5.4.3
        to_string(cn)
      _ ->
        nil
    end
  end)
end

defp extract_san_from_extensions(extensions) when is_list(extensions) do
  # TODO: Extract Subject Alternative Name extension
  # OID for SAN: 2.5.29.17
  []
end

defp extract_san_from_extensions(_), do: []

defp verify_identity(identity, _otp_cert) do
  # Map certificate identity to registered nickname
  # Option 1: Direct mapping (CN must match nickname)
  # Option 2: Use fingerprint mapping from config

  sasl_config = Application.get_env(:elixircd, :sasl, [])
  external_config = sasl_config[:external] || []
  cert_mappings = external_config[:cert_mappings] || %{}

  # Get certificate fingerprint
  fingerprint = compute_cert_fingerprint(otp_cert)

  # Check if fingerprint is mapped to an account
  case Map.get(cert_mappings, fingerprint) do
    nil ->
      # Try direct CN mapping
      verify_cn_identity(identity)

    nickname ->
      # Use mapped nickname
      case RegisteredNicks.get_by_nickname(nickname) do
        {:ok, _} -> {:ok, nickname}
        {:error, _} -> {:error, "Mapped account not found"}
      end
  end
end

defp compute_cert_fingerprint({:OTPCertificate, _tbs, _algo, _sig} = cert) do
  cert_der = :public_key.pkix_encode(:OTPCertificate, cert, :otp)
  :crypto.hash(:sha256, cert_der) |> Base.encode16(case: :lower)
end

defp verify_cn_identity(cn) do
  alias ElixIRCd.Repositories.RegisteredNicks

  case RegisteredNicks.get_by_nickname(cn) do
    {:ok, registered_nick} -> {:ok, registered_nick.nickname}
    {:error, _} -> {:error, "Certificate identity not registered: #{cn}"}
  end
end
```

#### 6.1.3. Adicionar configuração de CA trust

**Adicionar validação de certificado contra CA configurada:**
```elixir
defp validate_cert_chain(user) do
  sasl_config = Application.get_env(:elixircd, :sasl, [])
  external_config = sasl_config[:external] || []
  ca_cert_file = external_config[:ca_cert_file]

  if ca_cert_file && File.exists?(ca_cert_file) do
    # Load CA cert and validate chain
    # This requires integration with :ssl module
    :ok  # TODO: implement chain validation
  else
    # No CA configured, accept any cert (insecure!)
    Logger.warning("EXTERNAL SASL: No CA certificate configured, accepting any client cert")
    :ok
  end
end
```

---

## 7. ANÁLISE DO MECANISMO OAUTHBEARER

### 7.1. ⚠️ **IMPLEMENTAÇÃO PARCIAL: Validação JWT básica**

**Arquivo:** `lib/elixircd/commands/authenticate/oauthbearer.ex`

**Problemas:**

#### 7.1.1. Não verifica assinatura JWT

**Código Atual (linha 90-100):**
```elixir
defp decode_and_verify_jwt(token) do
  # Basic JWT structure validation
  case String.split(token, ".") do
    [_header, payload, _signature] ->
      # In production, verify signature here
      decode_jwt_payload(payload)

    _ ->
      {:error, :invalid_token}
  end
end
```

**Correção Necessária:**

Adicionar biblioteca Joken ou Guardian para validação JWT completa.

**mix.exs:**
```elixir
{:joken, "~> 2.6"}
```

**Atualizar código:**
```elixir
defp decode_and_verify_jwt(token) do
  sasl_config = Application.get_env(:elixircd, :sasl, [])
  oauth_config = sasl_config[:oauthbearer] || []
  jwt_config = oauth_config[:jwt] || []

  signer = get_jwt_signer(jwt_config)

  # Create token verifier
  extra_validators = %{}

  extra_validators = if jwt_config[:issuer] do
    Map.put(extra_validators, "iss", jwt_config[:issuer])
  else
    extra_validators
  end

  extra_validators = if jwt_config[:audience] do
    Map.put(extra_validators, "aud", jwt_config[:audience])
  else
    extra_validators
  end

  case Joken.verify(token, signer, extra_validators) do
    {:ok, claims} ->
      {:ok, claims}

    {:error, reason} ->
      Logger.debug("JWT verification failed: #{inspect(reason)}")
      {:error, :invalid_token}
  end
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
```

#### 7.1.2. Não implementa OAuth introspection

**Adicionar suporte a token introspection:**

**Novo arquivo:** `lib/elixircd/sasl/oauth_introspection.ex`
```elixir
defmodule ElixIRCd.Sasl.OAuthIntrospection do
  @moduledoc """
  OAuth 2.0 Token Introspection (RFC 7662).
  """

  require Logger

  @doc """
  Introspect an OAuth token via configured endpoint.
  """
  @spec introspect(String.t()) :: {:ok, map()} | {:error, atom()}
  def introspect(token) do
    sasl_config = Application.get_env(:elixircd, :sasl, [])
    oauth_config = sasl_config[:oauthbearer] || []
    introspection_config = oauth_config[:introspection] || []

    if introspection_config[:enabled] do
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
```

**Atualizar validate_token em oauthbearer.ex:**
```elixir
defp validate_token(token) do
  sasl_config = Application.get_env(:elixircd, :sasl, [])
  oauth_config = sasl_config[:oauthbearer] || []
  introspection_config = oauth_config[:introspection] || []

  # Try introspection first if enabled
  if introspection_config[:enabled] do
    case ElixIRCd.Sasl.OAuthIntrospection.introspect(token) do
      {:ok, claims} ->
        extract_identity_from_claims(claims)

      {:error, _reason} ->
        # Fall back to JWT validation if introspection fails
        decode_and_verify_jwt(token)
    end
  else
    # Use JWT validation
    decode_and_verify_jwt(token)
  end
end

defp extract_identity_from_claims(claims) do
  case Map.get(claims, "sub") do
    nil -> {:error, :invalid_token}
    identity -> {:ok, identity}
  end
end
```

#### 7.1.3. Não verifica TLS

**Adicionar verificação:**
```elixir
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
  # existing implementation
  with {:ok, decoded} <- Base.decode64(data),
       # ...
end
```

---

## 8. INTEGRAÇÃO COM NICKSERV

### 8.1. ✅ **BOM: Compatibilidade com identified_as**

**Pontos Positivos:**
- SASL e NickServ usam o mesmo campo `identified_as`
- Ambos adicionam mode `+r`
- Ambos atualizam `last_seen_at`

### 8.2. ⚠️ **PROBLEMA: SASL não impede IDENTIFY posterior**

**Cenário:**
1. Usuário autentica via SASL como "Alice"
2. Usuário pode executar `/msg NickServ IDENTIFY Bob password`
3. Isso muda a conta identificada

**Solução:**
Adicionar validação em `identify.ex`:

```elixir
defp identify_nickname(user, nickname, password) do
  Logger.debug("IDENTIFY attempt for nickname #{nickname} from #{user_mask(user)}")

  cond do
    user.sasl_authenticated && user.identified_as != nil ->
      notify(user, "You authenticated via SASL. Please /msg NickServ LOGOUT first, then IDENTIFY.")

    user.identified_as && user.identified_as != nickname ->
      notify(user, "You are already identified as \x02#{user.identified_as}\x02. Please /msg NickServ LOGOUT first.")

    user.identified_as == nickname ->
      notify(user, "You are already identified as \x02#{nickname}\x02.")

    true ->
      verify_nickname_and_password(user, nickname, password)
  end
end
```

### 8.3. ⚠️ **PROBLEMA: Logout não limpa flag sasl_authenticated**

**Arquivo:** `lib/elixircd/services/nickserv/logout.ex`

**Adicionar:**
```elixir
updated_user = Users.update(user, %{
  identified_as: nil,
  sasl_authenticated: false  # <- ADICIONAR ESTA LINHA
})
```

### 8.4. ❌ **FALTA: Notificar ACCOUNT-NOTIFY após SASL**

**Problema:**
O código atual não envia notificação ACCOUNT quando a autenticação SASL completa.

**Arquivo:** `lib/elixircd/commands/authenticate.ex`

**Adicionar em `complete_sasl_authentication` e `complete_scram_authentication`:**
```elixir
defp complete_sasl_authentication(user, registered_nick) do
  # ... existing code ...

  # Send ACCOUNT notification
  notify_account_change(updated_user, registered_nick.nickname)
end

defp notify_account_change(user, account) do
  account_notify_supported = Application.get_env(:elixircd, :capabilities)[:account_notify] || false

  if account_notify_supported do
    watchers = Users.get_in_shared_channels_with_capability(user, "ACCOUNT-NOTIFY", true)

    if watchers != [] do
      %Message{command: "ACCOUNT", params: [account]}
      |> Dispatcher.broadcast(user, watchers)
    end
  end

  :ok
end
```

---

## 9. COMPORTAMENTOS E RESPOSTAS IRC

### 9.1. ⚠️ **PROBLEMA: Numerics incompletos**

**Arquivo:** `lib/elixircd/message.ex`

**Verificar se todos os numerics SASL estão mapeados:**
```elixir
defp numeric_reply(:rpl_loggedin), do: "900"       # ✅ OK
defp numeric_reply(:rpl_loggedout), do: "901"      # ✅ OK
defp numeric_reply(:err_nicklocked), do: "902"     # ✅ OK
defp numeric_reply(:rpl_saslsuccess), do: "903"    # ✅ OK
defp numeric_reply(:err_saslfail), do: "904"       # ✅ OK
defp numeric_reply(:err_sasltoolong), do: "905"    # ✅ OK
defp numeric_reply(:err_saslaborted), do: "906"    # ✅ OK
defp numeric_reply(:err_saslalready), do: "907"    # ✅ OK
defp numeric_reply(:rpl_saslmechs), do: "908"      # ✅ OK
```

**Todos presentes!** ✅

### 9.2. ⚠️ **PROBLEMA: Formato de 900 RPL_LOGGEDIN incorreto**

**RFC Format:**
```
:server 900 <nick> <nick>!<user>@<host> <account> :You are now logged in as <account>
```

**Código Atual (authenticate.ex linha 437-446):**
```elixir
%Message{
  command: :rpl_loggedin,
  params: [
    user_reply(updated_user),
    user_mask(updated_user),
    account_name
  ],
  trailing: "You are now logged in as #{account_name}"
}
```

**Verificar se está correto:**
- `user_reply(updated_user)` retorna nick ✅
- `user_mask(updated_user)` retorna nick!user@host ✅
- `account_name` ✅
- trailing ✅

**Está correto!** ✅

### 9.3. ❌ **PROBLEMA: Não usa 902 ERR_NICKLOCKED**

**Caso de uso:**
Quando uma conta está bloqueada ou suspensa, deveria usar 902 ao invés de 904.

**Adicionar verificação:**

**Novo campo em RegisteredNick.t():**
```elixir
:locked,
:lock_reason,
```

**Verificar em authenticate_user:**
```elixir
defp authenticate_user(user, username, password) do
  Logger.debug("SASL authentication attempt for user #{username} from #{user_mask(user)}")

  case RegisteredNicks.get_by_nickname(username) do
    {:ok, registered_nick} ->
      if registered_nick.locked do
        %Message{
          command: :err_nicklocked,
          params: [user_reply(user)],
          trailing: registered_nick.lock_reason || "Account is locked"
        }
        |> Dispatcher.broadcast(:server, user)

        SaslSessions.delete(user.pid)
      else
        verify_password(user, registered_nick, password)
      end

    {:error, :registered_nick_not_found} ->
      # ... existing code
  end
end
```

---

## 10. TESTES

### 10.1. ✅ **BOM: Cobertura de testes PLAIN**

**Arquivo:** `test/elixircd/commands/authenticate_test.exs`

**Testes existentes:**
- ✅ Autenticação com credenciais válidas
- ✅ Falha com senha inválida
- ✅ Falha com usuário inexistente
- ✅ Falha com base64 inválido
- ✅ Abort com `*`
- ✅ Mensagem muito longa
- ✅ Fragmentação de mensagens

### 10.2. ⚠️ **FALTA: Testes para SCRAM completos**

**Arquivo:** `test/elixircd/commands/authenticate/scram_test.exs`

**Adicionar testes:**
```elixir
describe "SCRAM-SHA-256 full authentication flow" do
  test "completes full authentication with valid credentials" do
    # Test client-first, server-first, client-final, server-final, final +
  end

  test "fails with incorrect password in client-final" do
    # Test proof verification failure
  end

  test "fails if SCRAM credentials not found" do
    # User exists but no SCRAM creds
  end

  test "handles nonce mismatch" do
    # Client sends different nonce in client-final
  end

  test "validates channel binding correctly" do
    # Test c=biws (no channel binding)
  end
end
```

### 10.3. ⚠️ **FALTA: Testes para EXTERNAL**

**Criar:** `test/elixircd/commands/authenticate/external_test.exs`

```elixir
describe "EXTERNAL authentication" do
  test "succeeds with valid client certificate" do
    # Mock cert extraction
  end

  test "fails without TLS" do
    # TCP connection
  end

  test "fails with no client certificate" do
    # TLS but no cert
  end

  test "fails with unmapped certificate" do
    # Cert exists but not mapped to account
  end
end
```

### 10.4. ⚠️ **FALTA: Testes para OAUTHBEARER**

**Arquivo:** `test/elixircd/commands/authenticate/oauthbearer_test.exs`

**Adicionar:**
```elixir
describe "OAUTHBEARER with JWT validation" do
  test "succeeds with valid JWT" do
    # Create valid JWT with configured secret
  end

  test "fails with expired JWT" do
    # exp claim in past
  end

  test "fails with invalid signature" do
    # Wrong secret
  end

  test "validates issuer claim" do
    # Wrong iss
  end

  test "validates audience claim" do
    # Wrong aud
  end
end

describe "OAUTHBEARER with introspection" do
  test "succeeds with active token" do
    # Mock HTTP introspection response
  end

  test "fails with inactive token" do
    # active: false
  end

  test "handles network errors" do
    # Timeout or connection refused
  end
end
```

### 10.5. ⚠️ **FALTA: Testes de integração SASL + NickServ**

**Criar:** `test/integration/sasl_nickserv_test.exs`

```elixir
describe "SASL and NickServ integration" do
  test "user authenticated via SASL cannot IDENTIFY as different user" do
    # ...
  end

  test "user can LOGOUT after SASL auth and IDENTIFY as different user" do
    # ...
  end

  test "SASL auth and NickServ IDENTIFY both set identified_as" do
    # ...
  end

  test "ACCOUNT-NOTIFY works after SASL authentication" do
    # ...
  end
end
```

---

## 11. DOCUMENTAÇÃO E CÓDIGO FALTANTE

### 11.1. ❌ **FALTA: Documentação de uso**

**Criar:** `docs/SASL_AUTHENTICATION.md`

```markdown
# SASL Authentication in ElixIRCd

## Overview

ElixIRCd supports SASL authentication via the IRCv3 SASL extension...

## Supported Mechanisms

### PLAIN
- Username/password authentication
- **Security:** Requires TLS (configurable)
- **Use case:** Simple authentication

### SCRAM-SHA-256 / SCRAM-SHA-512
- Challenge-response authentication
- **Security:** No password transmitted
- **Use case:** Secure authentication without TLS requirement

### EXTERNAL
- TLS client certificate authentication
- **Security:** Requires TLS + client certificate
- **Use case:** Certificate-based authentication

### OAUTHBEARER
- OAuth 2.0 bearer token authentication
- **Security:** Requires TLS (configurable)
- **Use case:** Integration with OAuth providers

## Configuration

See `config/elixircd.exs`:

```elixir
sasl: [
  plain: [enabled: true, require_tls: true],
  scram: [enabled: true, iterations: 4096],
  external: [enabled: false, ca_cert_file: nil],
  oauthbearer: [enabled: false, jwt: [...]]
]
```

## Client Usage Examples

### Using PLAIN with irssi
```
/CAP REQ :sasl
/AUTHENTICATE PLAIN
... (client sends base64 encoded credentials)
```

...
```

### 11.2. ❌ **FALTA: Migração para adicionar campos**

**Criar:** `lib/elixircd/migrations/add_sasl_fields.ex`

```elixir
defmodule ElixIRCd.Migrations.AddSaslFields do
  @moduledoc """
  Adds SASL-related fields to existing tables.

  Run with: ElixIRCd.Migrations.AddSaslFields.run()
  """

  require Logger

  def run do
    Memento.transaction!(fn ->
      # Add sasl_attempts to existing users
      ElixIRCd.Tables.User
      |> Memento.Query.all()
      |> Enum.each(fn user ->
        if Map.get(user, :sasl_attempts) == nil do
          updated = Map.put(user, :sasl_attempts, 0)
          Memento.Query.write(updated)
        end
      end)

      # Create SCRAM credentials table
      Memento.Table.create(ElixIRCd.Tables.ScramCredential)

      Logger.info("SASL migration completed successfully")
    end)
  end
end
```

---

## 12. CHECKLIST DE IMPLEMENTAÇÃO

### 12.1. Configuração
- [ ] Adicionar configuração completa de SASL em `config/elixircd.exs`
- [ ] Adicionar verificação de configuração individual por mecanismo
- [ ] Implementar build_sasl_capability_value em cap.ex

### 12.2. Comando AUTHENTICATE
- [ ] Adicionar validação de CAP SASL negociado
- [ ] Adicionar verificação de TLS para PLAIN
- [ ] Adicionar verificação de TLS para OAUTHBEARER
- [ ] Implementar timeout de sessão SASL
- [ ] Implementar rate limiting de tentativas
- [ ] Adicionar contador sasl_attempts ao User.t()

### 12.3. Mecanismo PLAIN
- [ ] Adicionar suporte completo a authzid
- [ ] Verificar require_tls da configuração

### 12.4. Mecanismo SCRAM
- [ ] Criar tabela ScramCredential
- [ ] Criar repositório ScramCredentials
- [ ] Atualizar NickServ REGISTER para gerar credenciais SCRAM
- [ ] Atualizar NickServ password change para gerar credenciais SCRAM
- [ ] Corrigir derive_keys_from_hash para usar credenciais reais
- [ ] Implementar verify_client_proof corretamente com XOR
- [ ] Implementar normalize_password com SASLprep básico
- [ ] Adicionar suporte a AUTHENTICATE + final
- [ ] Atualizar process_scram_auth para esperar + final

### 12.5. Mecanismo EXTERNAL
- [ ] Adicionar tls_peer_cert e tls_cert_verified ao User.t()
- [ ] Integrar extração de peer certificate do transport
- [ ] Implementar extract_certificate_identity
- [ ] Implementar validação de cadeia de certificados
- [ ] Adicionar mapeamento de fingerprint para contas
- [ ] Adicionar suporte a Subject CN
- [ ] Adicionar suporte a Subject Alternative Name

### 12.6. Mecanismo OAUTHBEARER
- [ ] Adicionar biblioteca Joken para JWT
- [ ] Implementar verificação de assinatura JWT
- [ ] Implementar validação de claims (iss, aud, exp)
- [ ] Criar módulo OAuthIntrospection
- [ ] Adicionar HTTPoison para introspection
- [ ] Implementar fallback JWT quando introspection falha
- [ ] Adicionar verificação de TLS

### 12.7. Integração NickServ
- [ ] Impedir IDENTIFY após SASL authentication
- [ ] Atualizar LOGOUT para limpar sasl_authenticated
- [ ] Adicionar ACCOUNT-NOTIFY após SASL
- [ ] Sincronizar credenciais SCRAM em password change

### 12.8. Numerics e Respostas
- [ ] Implementar 902 ERR_NICKLOCKED para contas bloqueadas
- [ ] Adicionar campos locked e lock_reason ao RegisteredNick

### 12.9. Testes
- [ ] Adicionar testes SCRAM completos
- [ ] Criar testes EXTERNAL
- [ ] Expandir testes OAUTHBEARER
- [ ] Criar testes de integração SASL + NickServ
- [ ] Adicionar testes de timeout
- [ ] Adicionar testes de rate limiting

### 12.10. Documentação
- [ ] Criar docs/SASL_AUTHENTICATION.md
- [ ] Documentar configuração
- [ ] Adicionar exemplos de uso com clientes
- [ ] Documentar limitações (SASLprep, etc)

### 12.11. Infraestrutura
- [ ] Adicionar SessionMonitor ao supervisor
- [ ] Criar migration para campos SASL
- [ ] Adicionar SCRAM table ao Mnesia setup
- [ ] Atualizar mix.exs com dependências (Joken, HTTPoison)

---

## 13. PRIORIZAÇÃO

### 13.1. Prioridade CRÍTICA (deve ser feito antes de produção)
1. ✅ SCRAM: Armazenamento correto de credenciais
2. ✅ SCRAM: Implementar verify_client_proof com XOR
3. ✅ AUTHENTICATE: Validar CAP SASL negociado
4. ✅ PLAIN: Verificar TLS quando require_tls=true
5. ✅ Timeout de sessões SASL
6. ✅ Integração NickServ: Impedir IDENTIFY pós-SASL

### 13.2. Prioridade ALTA (importante para segurança)
7. ✅ Rate limiting de tentativas SASL
8. ✅ OAUTHBEARER: Implementar verificação JWT real
9. ✅ CAP: Anunciar mecanismos disponíveis
10. ✅ Configuração: Verificar mecanismos habilitados

### 13.3. Prioridade MÉDIA (funcionalidades completas)
11. ✅ EXTERNAL: Implementação completa
12. ✅ SCRAM: Suporte a + final
13. ✅ OAUTHBEARER: OAuth introspection
14. ✅ NickServ: Sincronizar credenciais SCRAM
15. ✅ Testes completos para todos os mecanismos

### 13.4. Prioridade BAIXA (melhorias)
16. ⚠️ SCRAM: Implementar SASLprep completo
17. ⚠️ PLAIN: Suporte completo a authzid
18. ⚠️ EXTERNAL: Validação de cadeia de certificados
19. ⚠️ Documentação completa
20. ⚠️ ERR_NICKLOCKED para contas bloqueadas

---

## 14. DEPENDÊNCIAS EXTERNAS

### 14.1. Bibliotecas Elixir Necessárias

**Adicionar ao `mix.exs`:**
```elixir
defp deps do
  [
    # ... existing deps
    {:joken, "~> 2.6"},           # JWT validation para OAUTHBEARER
    {:httpoison, "~> 2.2"},       # HTTP client para OAuth introspection
    {:jose, "~> 1.11"}            # Low-level JWT/JWS/JWE support
  ]
end
```

### 14.2. Certificados e Keys

Para EXTERNAL e OAUTHBEARER:
- CA certificate bundle para validação de certs
- Public key ou secret para JWT verification
- Client certificate mapping configuration

---

## 15. NOTAS FINAIS

### 15.1. Compatibilidade com Clientes IRC

Testado com:
- [ ] WeeChat
- [ ] irssi
- [ ] HexChat
- [ ] mIRC
- [ ] Textual
- [ ] IRCCloud

### 15.2. Conformidade com IRCv3

Implementação baseada em:
- ✅ IRCv3.1 SASL (https://ircv3.net/specs/extensions/sasl-3.1)
- ✅ IRCv3.2 SASL (https://ircv3.net/specs/extensions/sasl-3.2)
- ⚠️ RFC 4616 (PLAIN) - parcialmente implementado
- ⚠️ RFC 5802 (SCRAM) - estrutura correta, precisa armazenamento real
- ❌ RFC 4422 (EXTERNAL) - não implementado
- ⚠️ RFC 7628 (OAUTHBEARER) - estrutura básica, falta validação JWT

### 15.3. Limitações Conhecidas

1. **SASLprep não implementado**: Normalização de senha SCRAM é básica
2. **EXTERNAL não funcional**: Apenas stub, precisa integração com TLS
3. **OAUTHBEARER sem validação real**: Não verifica assinatura JWT
4. **Sem channel binding**: SCRAM não suporta channel binding (tls-unique)
5. **Sem reauth**: SASL 3.2 permite reauth pós-registro, não implementado

---

**FIM DA ANÁLISE**

**Data:** 2025-12-07
**Versão do Documento:** 1.0
**Status:** Análise Completa - Aguardando Implementação
