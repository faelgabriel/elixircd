defmodule ElixIRCd.Sasl.ScramSha256Test do
  use ExUnit.Case, async: true

  alias ElixIRCd.Sasl.ScramSha256

  test "authenticates a complete exchange and returns the server signature" do
    password = "correct horse battery staple"
    credentials = ScramSha256.derive(password, 4096)
    client_first_bare = "n=user,r=client-nonce"

    assert {:ok, server_first, state} =
             ScramSha256.start("n,," <> client_first_bare, fn "user" ->
               {:ok, "user", credentials, true}
             end)

    client_final = client_final(password, client_first_bare, server_first)
    assert {:ok, "v=" <> signature} = ScramSha256.finish(client_final, state)
    assert {:ok, decoded_signature} = Base.decode64(signature)
    assert byte_size(decoded_signature) == 32
  end

  test "rejects a wrong proof, nonce, unsupported binding and malformed escapes" do
    credentials = ScramSha256.derive("password", 4096)
    lookup = fn _username -> {:ok, "user", credentials, true} end

    assert {:ok, _server_first, state} = ScramSha256.start("n,,n=user,r=nonce", lookup)

    wrong_proof = "c=biws,r=#{state.combined_nonce},p=#{Base.encode64(:binary.copy(<<0>>, 32))}"
    assert {:error, :invalid_client_final} = ScramSha256.finish(wrong_proof, state)
    assert {:error, :invalid_client_final} = ScramSha256.finish("c=biws,r=other,p=AAAA", state)
    assert {:error, :invalid_client_first} = ScramSha256.start("p=tls-exporter,,n=user,r=nonce", lookup)
    assert {:error, :invalid_client_first} = ScramSha256.start("n,,n=bad=40name,r=nonce", lookup)
  end

  test "an intentionally unauthenticatable exchange cannot reveal whether an account exists" do
    credentials = ScramSha256.derive("random", 4096)

    assert {:ok, server_first, state} =
             ScramSha256.start("n,,n=missing,r=nonce", fn _username ->
               {:ok, "missing", credentials, false}
             end)

    client_final = client_final("random", "n=missing,r=nonce", server_first)
    assert {:error, :invalid_client_final} = ScramSha256.finish(client_final, state)
  end

  test "rejects invalid identities, lookup results, attributes and credential shapes" do
    credentials = ScramSha256.derive("password", 4096)
    valid = fn _ -> {:ok, "user", credentials, true} end

    assert {:error, :invalid_client_first} = ScramSha256.start("n,a=other,n=user,r=nonce", valid)
    assert {:error, :credentials_not_found} = ScramSha256.start("n,,n=user,r=nonce", fn _ -> :error end)
    assert {:error, :invalid_credentials} = ScramSha256.start("n,,n=user,r=nonce", fn _ -> :invalid end)
    assert {:error, :invalid_client_first} = ScramSha256.start("n,,n=user,n=again,r=nonce", valid)
    assert {:error, :invalid_client_first} = ScramSha256.start("n,,n=user", valid)
    assert {:error, :invalid_client_first} = ScramSha256.start("n,,n=bad=,r=nonce", valid)
    assert {:error, :invalid_client_first} = ScramSha256.start(<<"n,,n=", 255, ",r=nonce">>, valid)

    invalid_credentials = %{credentials | salt: "bad", stored_key: "bad", server_key: "bad"}

    assert {:error, :invalid_credentials} =
             ScramSha256.start("n,,n=user,r=nonce", fn _ -> {:ok, "user", invalid_credentials, true} end)
  end

  test "unescapes SCRAM usernames containing comma and equals" do
    credentials = ScramSha256.derive("password", 4096)

    assert {:ok, _server_first, %{account_name: "u,s=e"}} =
             ScramSha256.start("n,,n=u=2Cs=3De,r=nonce", fn "u,s=e" ->
               {:ok, "u,s=e", credentials, true}
             end)
  end

  defp client_final(password, client_first_bare, server_first) do
    attributes = parse_attributes(server_first)
    without_proof = "c=biws,r=#{attributes["r"]}"
    auth_message = client_first_bare <> "," <> server_first <> "," <> without_proof

    salted =
      :crypto.pbkdf2_hmac(
        :sha256,
        password,
        Base.decode64!(attributes["s"]),
        String.to_integer(attributes["i"]),
        32
      )

    client_key = :crypto.mac(:hmac, :sha256, salted, "Client Key")
    stored_key = :crypto.hash(:sha256, client_key)
    signature = :crypto.mac(:hmac, :sha256, stored_key, auth_message)
    without_proof <> ",p=" <> Base.encode64(:crypto.exor(client_key, signature))
  end

  defp parse_attributes(message) do
    message
    |> String.split(",")
    |> Map.new(fn part ->
      [key, value] = String.split(part, "=", parts: 2)
      {key, value}
    end)
  end
end
