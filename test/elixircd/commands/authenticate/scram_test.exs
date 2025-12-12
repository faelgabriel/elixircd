defmodule ElixIRCd.Commands.Authenticate.ScramTest do
  use ElixIRCd.DataCase, async: false

  import ElixIRCd.Factory

  alias ElixIRCd.Commands.Authenticate.Scram
  alias ElixIRCd.Tables.SaslSession
  alias ElixIRCd.Tables.ScramCredential

  describe "process_step/3 - client-first-message" do
    test "processes valid client-first-message" do
      seed_scram_credential("testuser", :sha256)
      client_first = "n,,n=testuser,r=clientnonce123"
      client_first_b64 = Base.encode64(client_first)

      assert {:continue, server_first_b64, state} =
               Scram.process_step(%{}, client_first_b64, :sha256)

      assert is_binary(server_first_b64)
      assert state.scram_step == 1
      assert state.username == "testuser"
      assert state.client_nonce == "clientnonce123"
    end

    test "handles invalid base64" do
      assert {:error, _} = Scram.process_step(%{}, "invalid!base64", :sha256)
    end

    test "handles invalid client-first format" do
      invalid = Base.encode64("invalid format")
      assert {:error, _} = Scram.process_step(%{}, invalid, :sha256)
    end

    test "handles missing username" do
      invalid = Base.encode64("n,,r=nonce")
      assert {:error, _} = Scram.process_step(%{}, invalid, :sha256)
    end

    test "handles missing nonce" do
      invalid = Base.encode64("n,,n=user")
      assert {:error, _} = Scram.process_step(%{}, invalid, :sha256)
    end

    test "handles SASL escaped username" do
      # Username with comma (escaped as =2C)
      seed_scram_credential("user,name", :sha256)
      client_first = "n,,n=user=2Cname,r=nonce"
      client_first_b64 = Base.encode64(client_first)

      assert {:continue, _, state} = Scram.process_step(%{}, client_first_b64, :sha256)
      assert state.username == "user,name"
    end

    test "handles SASL escaped equals sign" do
      # Username with equals (escaped as =3D)
      seed_scram_credential("user=name", :sha256)
      client_first = "n,,n=user=3Dname,r=nonce"
      client_first_b64 = Base.encode64(client_first)

      assert {:continue, _, state} = Scram.process_step(%{}, client_first_b64, :sha256)
      assert state.username == "user=name"
    end
  end

  describe "process_step/3 - client-final-message" do
    test "handles invalid state" do
      state = %{scram_step: 99}
      assert {:error, "Invalid SCRAM state"} = Scram.process_step(state, "data", :sha256)
    end

    test "handles invalid base64 in client-final" do
      state = %{
        scram_step: 1,
        username: "testuser",
        client_nonce: "clientnonce",
        server_nonce: "servernonce",
        full_nonce: "clientnonceservernonce",
        salt: <<1, 2, 3>>,
        iterations: 4096,
        client_first_bare: "n=testuser,r=clientnonce",
        server_first: "r=clientnonceservernonce,s=AQID,i=4096"
      }

      assert {:error, _} = Scram.process_step(state, "invalid!base64", :sha256)
    end

    test "handles invalid client-final format" do
      state = %{
        scram_step: 1,
        username: "testuser",
        client_nonce: "clientnonce",
        server_nonce: "servernonce",
        full_nonce: "clientnonceservernonce",
        salt: <<1, 2, 3>>,
        iterations: 4096,
        client_first_bare: "n=testuser,r=clientnonce",
        server_first: "r=clientnonceservernonce,s=AQID,i=4096"
      }

      invalid = Base.encode64("invalid")
      assert {:error, _} = Scram.process_step(state, invalid, :sha256)
    end

    test "handles nonce mismatch" do
      state = %{
        scram_step: 1,
        username: "testuser",
        client_nonce: "clientnonce",
        server_nonce: "servernonce",
        full_nonce: "clientnonceservernonce",
        salt: <<1, 2, 3>>,
        iterations: 4096,
        client_first_bare: "n=testuser,r=clientnonce",
        server_first: "r=clientnonceservernonce,s=AQID,i=4096"
      }

      # Client final with wrong nonce
      client_final = "c=biws,r=wrongnonce,p=#{Base.encode64("proof")}"
      client_final_b64 = Base.encode64(client_final)

      assert {:error, _} = Scram.process_step(state, client_final_b64, :sha256)
    end

    test "handles non-existent user" do
      Memento.transaction!(fn ->
        state = %{
          scram_step: 1,
          username: "nonexistentuser",
          client_nonce: "clientnonce",
          server_nonce: "servernonce",
          full_nonce: "clientnonceservernonce",
          salt: <<1, 2, 3>>,
          iterations: 4096,
          client_first_bare: "n=nonexistentuser,r=clientnonce",
          server_first: "r=clientnonceservernonce,s=AQID,i=4096"
        }

        # Client final with correct nonce
        client_final = "c=biws,r=clientnonceservernonce,p=#{Base.encode64("proof")}"
        client_final_b64 = Base.encode64(client_final)

        assert {:error, _} = Scram.process_step(state, client_final_b64, :sha256)
      end)
    end
  end

  describe "process_step/3 - SHA-512" do
    test "processes with SHA-512 algorithm" do
      seed_scram_credential("testuser", :sha512)
      client_first = "n,,n=testuser,r=clientnonce456"
      client_first_b64 = Base.encode64(client_first)

      assert {:continue, server_first_b64, state} =
               Scram.process_step(%{}, client_first_b64, :sha512)

      assert is_binary(server_first_b64)
      assert state.scram_algo == :sha512
    end
  end

  describe "process_step/3 - parse_client_final edge cases" do
    test "handles client-final with missing channel binding" do
      state = %{
        scram_step: 1,
        username: "testuser",
        client_nonce: "clientnonce",
        server_nonce: "servernonce",
        full_nonce: "clientnonceservernonce",
        salt: <<1, 2, 3>>,
        iterations: 4096,
        client_first_bare: "n=testuser,r=clientnonce",
        server_first: "r=clientnonceservernonce,s=AQID,i=4096"
      }

      # Client final missing c= field
      client_final = "r=clientnonceservernonce,p=#{Base.encode64("proof")}"
      client_final_b64 = Base.encode64(client_final)

      assert {:error, _} = Scram.process_step(state, client_final_b64, :sha256)
    end
  end

  describe "process_step/3 - edge cases" do
    test "handles client-first with authzid" do
      seed_scram_credential("testuser", :sha256)
      client_first = "n,a=authzid,n=testuser,r=nonce"
      client_first_b64 = Base.encode64(client_first)

      assert {:continue, _, state} = Scram.process_step(%{}, client_first_b64, :sha256)
      assert state.username == "testuser"
    end

    test "handles client-final missing fields" do
      state = %{
        scram_step: 1,
        username: "testuser",
        client_nonce: "clientnonce",
        server_nonce: "servernonce",
        full_nonce: "clientnonceservernonce",
        salt: <<1, 2, 3>>,
        iterations: 4096,
        client_first_bare: "n=testuser,r=clientnonce",
        server_first: "r=clientnonceservernonce,s=AQID,i=4096"
      }

      # Client final missing proof
      client_final = "c=biws,r=clientnonceservernonce"
      client_final_b64 = Base.encode64(client_final)

      assert {:error, _} = Scram.process_step(state, client_final_b64, :sha256)
    end

    test "handles client-final with valid proof but wrong user" do
      Memento.transaction!(fn ->
        state = %{
          scram_step: 1,
          username: "wronguser",
          client_nonce: "clientnonce",
          server_nonce: "servernonce",
          full_nonce: "clientnonceservernonce",
          salt: <<1, 2, 3>>,
          iterations: 4096,
          client_first_bare: "n=wronguser,r=clientnonce",
          server_first: "r=clientnonceservernonce,s=AQID,i=4096"
        }

        # Client final with valid format but user doesn't exist
        proof = Base.encode64("someproof")
        client_final = "c=biws,r=clientnonceservernonce,p=#{proof}"
        client_final_b64 = Base.encode64(client_final)

        assert {:error, _} = Scram.process_step(state, client_final_b64, :sha256)
      end)
    end
  end

  describe "process_step/3 - full SCRAM flow" do
    setup do
      original_sasl = Application.get_env(:elixircd, :sasl)

      Application.put_env(:elixircd, :sasl,
        scram: [
          enabled: true,
          iterations: 4096,
          algorithms: ["SHA-256"]
        ]
      )

      on_exit(fn -> Application.put_env(:elixircd, :sasl, original_sasl) end)

      :ok
    end

    test "completes SCRAM-SHA-256 exchange with valid credentials" do
      Memento.transaction!(fn ->
        password = "secretpass"
        user = insert(:user, registered: false, capabilities: ["SASL"], nick: "TempNick")

        # Prepare registered nick and SCRAM credentials
        insert(:registered_nick,
          nickname: "ScramUser",
          password_hash: Argon2.hash_pwd_salt(password)
        )

        seed_scram_credential("ScramUser", :sha256, 4096, password)

        # Start SASL session and simulate client-first exchange
        session =
          %SaslSession{
            user_pid: user.pid,
            mechanism: "SCRAM-SHA-256",
            buffer: "",
            state: nil,
            created_at: DateTime.utc_now()
          }

        Memento.Query.write(session)

        client_nonce = "clientnonce123"
        client_first = "n,,n=ScramUser,r=#{client_nonce}"
        client_first_b64 = Base.encode64(client_first)

        assert {:continue, server_first_b64, state} =
                 Scram.process_step(%{}, client_first_b64, :sha256)

        # Persist state as Authenticate would
        updated_session = %SaslSession{session | state: state, buffer: ""}
        Memento.Query.write(updated_session)

        server_first = Base.decode64!(server_first_b64)
        assert server_first =~ "r=#{client_nonce}"
        assert server_first =~ "s="
        assert server_first =~ "i=4096"

        client_final_b64 = build_client_final(state, password, :sha256)

        assert {:success, server_final_b64, registered_nick} =
                 Scram.process_step(state, client_final_b64, :sha256)

        server_final = Base.decode64!(server_final_b64)
        assert server_final =~ "v="
        assert registered_nick.nickname == "ScramUser"
      end)
    end
  end

  defp build_client_final(state, password, :sha256) do
    hash = :sha256
    key_length = 32

    salted_password =
      :crypto.pbkdf2_hmac(
        hash,
        password,
        state.salt,
        state.iterations,
        key_length
      )

    client_key = :crypto.mac(:hmac, hash, salted_password, "Client Key")
    stored_key = :crypto.hash(hash, client_key)

    auth_message = build_auth_message(state.client_first_bare, state.server_first, "c=biws,r=#{state.full_nonce}")
    client_signature = :crypto.mac(:hmac, hash, stored_key, auth_message)
    client_proof = xor_bytes(client_key, client_signature)

    proof_b64 = Base.encode64(client_proof)
    Base.encode64("c=biws,r=#{state.full_nonce},p=#{proof_b64}")
  end

  defp xor_bytes(a, b) when byte_size(a) == byte_size(b) do
    a_bytes = :binary.bin_to_list(a)
    b_bytes = :binary.bin_to_list(b)

    a_bytes
    |> Enum.zip(b_bytes)
    |> Enum.map(fn {x, y} -> Bitwise.bxor(x, y) end)
    |> :binary.list_to_bin()
  end

  defp build_auth_message(client_first_bare, server_first, client_final_without_proof) do
    "#{client_first_bare},#{server_first},#{client_final_without_proof}"
  end

  defp seed_scram_credential(username, algorithm, iterations \\ 4096, password \\ "password") do
    cred = ScramCredential.generate_from_password(username, password, algorithm, iterations)

    Memento.transaction!(fn ->
      Memento.Query.write(cred)
    end)

    password
  end
end
