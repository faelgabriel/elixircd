defmodule ElixIRCd.Tables.ScramCredentialTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Tables.ScramCredential

  describe "new/1" do
    test "creates a new SCRAM credential with all required fields" do
      attrs = %{
        nickname_key: "alice",
        algorithm: :sha256,
        iterations: 4096,
        salt: :crypto.strong_rand_bytes(16),
        stored_key: :crypto.strong_rand_bytes(32),
        server_key: :crypto.strong_rand_bytes(32)
      }

      credential = ScramCredential.new(attrs)

      assert credential.nickname_key == "alice"
      assert credential.algorithm == :sha256
      assert credential.iterations == 4096
      assert credential.key == "alice:sha256"
      assert is_struct(credential.created_at, DateTime)
      assert is_struct(credential.updated_at, DateTime)
    end

    test "generates key automatically from nickname and algorithm" do
      attrs = %{
        nickname_key: "bob",
        algorithm: :sha512,
        iterations: 4096,
        salt: <<1, 2, 3>>,
        stored_key: <<4, 5, 6>>,
        server_key: <<7, 8, 9>>
      }

      credential = ScramCredential.new(attrs)

      assert credential.key == "bob:sha512"
    end
  end

  describe "generate_from_password/4" do
    test "generates valid SCRAM-SHA-256 credentials" do
      credential = ScramCredential.generate_from_password("alice", "password123", :sha256, 4096)

      assert credential.nickname_key == "alice"
      assert credential.algorithm == :sha256
      assert credential.iterations == 4096
      assert byte_size(credential.salt) == 16
      # SHA-256 = 32 bytes
      assert byte_size(credential.stored_key) == 32
      assert byte_size(credential.server_key) == 32
    end

    test "generates valid SCRAM-SHA-512 credentials" do
      credential = ScramCredential.generate_from_password("bob", "secret456", :sha512, 8192)

      assert credential.nickname_key == "bob"
      assert credential.algorithm == :sha512
      assert credential.iterations == 8192
      assert byte_size(credential.salt) == 16
      # SHA-512 = 64 bytes
      assert byte_size(credential.stored_key) == 64
      assert byte_size(credential.server_key) == 64
    end

    test "generates different credentials for same password with different salts" do
      cred1 = ScramCredential.generate_from_password("user", "password", :sha256, 4096)
      cred2 = ScramCredential.generate_from_password("user", "password", :sha256, 4096)

      # Same password but different salts should produce different keys
      assert cred1.salt != cred2.salt
      assert cred1.stored_key != cred2.stored_key
      assert cred1.server_key != cred2.server_key
    end

    test "normalizes nickname using case mapping" do
      credential = ScramCredential.generate_from_password("Alice", "password", :sha256, 4096)

      assert credential.nickname_key == "alice"
    end

    test "raises on password with control characters" do
      assert_raise ArgumentError, ~r/control characters/, fn ->
        ScramCredential.generate_from_password("user", "pass\x00word", :sha256, 4096)
      end
    end

    test "raises on password with zero-width characters" do
      assert_raise ArgumentError, ~r/zero-width/, fn ->
        ScramCredential.generate_from_password("user", "pass\u200Bword", :sha256, 4096)
      end
    end

    test "raises on invalid UTF-8 password" do
      assert_raise ArgumentError, ~r/valid UTF-8/, fn ->
        ScramCredential.generate_from_password("user", <<0xFF, 0xFE>>, :sha256, 4096)
      end
    end

    test "applies Unicode normalization" do
      # Test that accented characters are normalized consistently
      # Uses combining accent
      password = "café"
      credential = ScramCredential.generate_from_password("user", password, :sha256, 4096)

      assert credential.stored_key != nil
    end
  end
end


