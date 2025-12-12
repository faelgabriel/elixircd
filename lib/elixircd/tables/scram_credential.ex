defmodule ElixIRCd.Tables.ScramCredential do
  @moduledoc """
  Stores SCRAM authentication credentials.

  When a user registers or changes their password, we store SCRAM credentials
  separately to enable SCRAM authentication while maintaining Argon2 for IDENTIFY.

  SCRAM requires storing:
  - salt: Random salt used for key derivation
  - stored_key: H(ClientKey) used to verify client authentication
  - server_key: ServerKey used to prove server identity to client
  - iterations: Number of PBKDF2 iterations

  These are derived from the user's password using PBKDF2-HMAC as per RFC 5802.
  """

  use Memento.Table,
    attributes: [
      # Primary key: "nickname_key:algorithm" e.g., "alice:sha256"
      :key,
      # Normalized nickname (for indexing)
      :nickname_key,
      # :sha256 or :sha512
      :algorithm,
      # Number of PBKDF2 iterations
      :iterations,
      # Random salt (binary)
      :salt,
      # H(ClientKey) (binary)
      :stored_key,
      # ServerKey (binary)
      :server_key,
      :created_at,
      :updated_at
    ],
    index: [:nickname_key, :algorithm],
    type: :set

  @type t :: %__MODULE__{
          key: String.t(),
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
          optional(:key) => String.t(),
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

    # Generate key if not provided
    key =
      if attrs[:key] do
        attrs[:key]
      else
        "#{attrs[:nickname_key]}:#{attrs[:algorithm]}"
      end

    new_attrs =
      attrs
      |> Map.put(:key, key)
      |> Map.put_new(:created_at, now)
      |> Map.put_new(:updated_at, now)

    struct!(__MODULE__, new_attrs)
  end

  @doc """
  Generate SCRAM credentials from plaintext password.

  This follows RFC 5802 specification:
  1. Generate random salt
  2. Compute SaltedPassword = PBKDF2(password, salt, iterations)
  3. Compute ClientKey = HMAC(SaltedPassword, "Client Key")
  4. Compute StoredKey = H(ClientKey)
  5. Compute ServerKey = HMAC(SaltedPassword, "Server Key")
  """
  @spec generate_from_password(String.t(), String.t(), :sha256 | :sha512, pos_integer()) :: t()
  def generate_from_password(nickname, password, algorithm, iterations) do
    alias ElixIRCd.Utils.CaseMapping

    nickname_key = CaseMapping.normalize(nickname)
    hash_func = if algorithm == :sha256, do: :sha256, else: :sha512

    # Generate random salt (16 bytes recommended by RFC 5802)
    salt = :crypto.strong_rand_bytes(16)

    # Normalize password using basic SASLprep validation
    # Full RFC 4013 SASLprep would require stringprep library
    # This implementation does basic validation to catch common issues
    normalized_password = normalize_password(password)

    # Compute SaltedPassword using PBKDF2
    # Key length: 32 bytes for SHA-256, 64 bytes for SHA-512
    key_length = if algorithm == :sha256, do: 32, else: 64

    salted_password =
      :crypto.pbkdf2_hmac(
        hash_func,
        normalized_password,
        salt,
        iterations,
        key_length
      )

    # Compute ClientKey = HMAC(SaltedPassword, "Client Key")
    client_key = :crypto.mac(:hmac, hash_func, salted_password, "Client Key")

    # Compute StoredKey = H(ClientKey)
    stored_key = :crypto.hash(hash_func, client_key)

    # Compute ServerKey = HMAC(SaltedPassword, "Server Key")
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

  # Normalize password using basic SASLprep validation.
  #
  # This implements a subset of RFC 4013 SASLprep:
  # - Validates UTF-8 encoding
  # - Rejects control characters
  # - Rejects zero-width characters
  # - Performs Unicode normalization (NFC)
  #
  # Full SASLprep would require a complete stringprep implementation.
  @spec normalize_password(String.t()) :: String.t()
  defp normalize_password(password) do
    # Validate UTF-8
    unless String.valid?(password) do
      raise ArgumentError, "Password must be valid UTF-8"
    end

    # Check for zero-width characters that could cause confusion
    # U+200B (Zero Width Space), U+200C (ZWNJ), U+200D (ZWJ), U+FEFF (Zero Width No-Break Space)
    if String.contains?(password, ["\u200B", "\u200C", "\u200D", "\uFEFF"]) do
      raise ArgumentError, "Password contains zero-width characters"
    end

    # Check for control characters (C0 and C1 control codes)
    if String.match?(password, ~r/[\x00-\x1F\x7F-\x9F]/) do
      raise ArgumentError, "Password contains invalid control characters"
    end

    # Apply Unicode normalization form C (NFC)
    # This ensures consistent representation of characters
    :unicode.characters_to_nfc_binary(password)
  end
end
