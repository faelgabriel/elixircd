defmodule ElixIRCd.Repositories.ScramCredentialsTest do
  @moduledoc false

  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Repositories.ScramCredentials
  alias ElixIRCd.Tables.ScramCredential

  describe "get/2" do
    test "returns credential for existing nickname and algorithm" do
      Memento.transaction!(fn ->
        credential = ScramCredential.generate_from_password("alice", "password", :sha256, 4096)
        Memento.Query.write(credential)
      end)

      assert {:ok, cred} = ScramCredentials.get("alice", :sha256)
      assert cred.nickname_key == "alice"
      assert cred.algorithm == :sha256
    end

    test "returns error for non-existent credential" do
      assert {:error, :not_found} = ScramCredentials.get("nonexistent", :sha256)
    end

    test "returns error for wrong algorithm" do
      Memento.transaction!(fn ->
        credential = ScramCredential.generate_from_password("bob", "password", :sha256, 4096)
        Memento.Query.write(credential)
      end)

      assert {:error, :not_found} = ScramCredentials.get("bob", :sha512)
    end
  end

  describe "get_all/1" do
    test "returns all credentials for a nickname" do
      Memento.transaction!(fn ->
        cred1 = ScramCredential.generate_from_password("alice", "password", :sha256, 4096)
        cred2 = ScramCredential.generate_from_password("alice", "password", :sha512, 4096)
        Memento.Query.write(cred1)
        Memento.Query.write(cred2)
      end)

      credentials = ScramCredentials.get_all("alice")

      assert length(credentials) == 2
      assert Enum.any?(credentials, fn c -> c.algorithm == :sha256 end)
      assert Enum.any?(credentials, fn c -> c.algorithm == :sha512 end)
    end

    test "returns empty list for nickname with no credentials" do
      credentials = ScramCredentials.get_all("nonexistent")

      assert credentials == []
    end
  end

  describe "upsert/1" do
    test "creates new credential" do
      credential = ScramCredential.generate_from_password("alice", "password", :sha256, 4096)

      assert credential = ScramCredentials.upsert(credential)

      assert {:ok, stored} = ScramCredentials.get("alice", :sha256)
      assert stored.stored_key == credential.stored_key
    end

    test "updates existing credential" do
      # Create initial credential
      Memento.transaction!(fn ->
        credential = ScramCredential.generate_from_password("bob", "oldpass", :sha256, 4096)
        Memento.Query.write(credential)
      end)

      # Update with new credential
      new_credential = ScramCredential.generate_from_password("bob", "newpass", :sha256, 4096)
      ScramCredentials.upsert(new_credential)

      # Verify updated
      {:ok, stored} = ScramCredentials.get("bob", :sha256)
      assert stored.stored_key == new_credential.stored_key
    end
  end

  describe "delete/2" do
    test "deletes existing credential" do
      Memento.transaction!(fn ->
        credential = ScramCredential.generate_from_password("alice", "password", :sha256, 4096)
        Memento.Query.write(credential)
      end)

      assert :ok = ScramCredentials.delete("alice", :sha256)
      assert {:error, :not_found} = ScramCredentials.get("alice", :sha256)
    end

    test "returns ok when credential doesn't exist" do
      assert :ok = ScramCredentials.delete("nonexistent", :sha256)
    end
  end

  describe "delete_all/1" do
    test "deletes all credentials for a nickname" do
      Memento.transaction!(fn ->
        cred1 = ScramCredential.generate_from_password("alice", "password", :sha256, 4096)
        cred2 = ScramCredential.generate_from_password("alice", "password", :sha512, 4096)
        Memento.Query.write(cred1)
        Memento.Query.write(cred2)
      end)

      assert :ok = ScramCredentials.delete_all("alice")

      assert {:error, :not_found} = ScramCredentials.get("alice", :sha256)
      assert {:error, :not_found} = ScramCredentials.get("alice", :sha512)
    end
  end

  describe "generate_and_store/2" do
    test "generates and stores credentials for configured algorithms" do
      original_config = Application.get_env(:elixircd, :sasl)
      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_config) end)

      Application.put_env(:elixircd, :sasl,
        scram: [
          iterations: 4096,
          algorithms: ["SHA-256", "SHA-512"]
        ]
      )

      assert :ok = ScramCredentials.generate_and_store("testuser", "testpass")

      assert {:ok, _} = ScramCredentials.get("testuser", :sha256)
      assert {:ok, _} = ScramCredentials.get("testuser", :sha512)
    end

    test "uses configured iterations" do
      original_config = Application.get_env(:elixircd, :sasl)
      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_config) end)

      Application.put_env(:elixircd, :sasl,
        scram: [
          iterations: 8192,
          algorithms: ["SHA-256"]
        ]
      )

      assert :ok = ScramCredentials.generate_and_store("testuser", "testpass")

      {:ok, cred} = ScramCredentials.get("testuser", :sha256)
      assert cred.iterations == 8192
    end
  end

  describe "exists?/2" do
    test "returns true when credential exists" do
      Memento.transaction!(fn ->
        credential = ScramCredential.generate_from_password("alice", "password", :sha256, 4096)
        Memento.Query.write(credential)
      end)

      assert ScramCredentials.exists?("alice", :sha256) == true
    end

    test "returns false when credential doesn't exist" do
      assert ScramCredentials.exists?("nonexistent", :sha256) == false
    end
  end
end


