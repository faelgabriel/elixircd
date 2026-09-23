defmodule ElixIRCd.Server.S2S.SASLTest do
  use ExUnit.Case, async: true

  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.SASL

  @client_info %{
    "secure_client" => true,
    "realhost" => "client.example",
    "address" => "192.0.2.1",
    "client_certfp" => nil
  }

  test "PLAIN decodes once, requires a secure client and returns only a binding" do
    uid = Identity.uid()
    account_id = Identity.uid()
    {:ok, state} = SASL.start(uid, Identity.nonce(), "PLAIN", @client_info)
    data = Base.encode64(<<0, "alice", 0, "secret">>)

    assert {:ok, finished, %{"uid" => ^uid, "account_id" => ^account_id}} =
             SASL.step(state, data, plain_lookup: fn "alice", "secret", @client_info -> {:ok, account_id} end)

    assert finished.done?
    refute Map.has_key?(finished, :password)
  end

  test "ECDSA challenge verifies the signature and fences extra steps" do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :secp256r1)
    uid = Identity.uid()
    account_id = Identity.uid()
    {:ok, state} = SASL.start(uid, Identity.nonce(), "ECDSA-NIST256P-CHALLENGE", @client_info)
    account_data = Base.encode64("alice")
    assert {:continue, challenged, %{"challenge" => encoded}} = SASL.step(state, account_data)
    {:ok, challenge} = Base.decode64(encoded)
    signature = :crypto.sign(:ecdsa, :sha256, {:digest, challenge}, [private_key, :secp256r1])

    assert {:ok, finished, %{"account_id" => ^account_id}} =
             SASL.step(challenged, Base.encode64(signature),
               ecdsa_lookup: fn ^uid, "alice", @client_info -> {:ok, public_key, account_id} end
             )

    assert finished.done?
    assert {:error, :sasl_already_complete} = SASL.step(finished, nil)
  end

  test "invalid base64 and insecure PLAIN fail closed" do
    uid = Identity.uid()
    {:ok, state} = SASL.start(uid, Identity.nonce(), "PLAIN", Map.put(@client_info, "secure_client", false))

    assert {:error, :plain_requires_secure_client} =
             SASL.step(state, "not-base64", plain_lookup: fn _, _, _ -> :error end)
  end

  test "decoded NUL data cannot escape the SASL mechanism as an IRC payload" do
    uid = Identity.uid()
    account_id = Identity.uid()
    {:ok, state} = SASL.start(uid, Identity.nonce(), "PLAIN", @client_info)
    data = Base.encode64(<<0, "alice", 0, "secret", 0, "injected-field">>)

    assert {:error, :invalid_plain_encoding} =
             SASL.step(state, data, plain_lookup: fn _, _, _ -> {:ok, account_id} end)
  end
end
