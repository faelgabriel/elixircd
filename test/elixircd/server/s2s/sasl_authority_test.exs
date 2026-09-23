defmodule ElixIRCd.Server.S2S.SASLAuthorityTest do
  use ElixIRCd.DataCase, async: false

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Server.S2S.SASLAuthority
  alias ElixIRCd.Tables.RegisteredNick.Settings

  test "looks up the authority-side ECDSA key by the requested account" do
    {public_key, _private_key} = :crypto.generate_key(:ecdh, :secp256r1)
    compressed = compress_public_key(public_key)
    encoded = Base.encode64(compressed, padding: false)

    account =
      Memento.transaction!(fn ->
        RegisteredNicks.create(%{
          nickname: "authority-ecdsa",
          password_hash: Argon2.hash_pwd_salt("unused"),
          settings: Settings.new(%{pubkey: encoded}),
          registered_by: "test"
        })
      end)

    assert {:ok, ^compressed, account_id} =
             SASLAuthority.ecdsa_lookup(
               Identity.uid(),
               account.nickname,
               %{"secure_client" => true}
             )

    assert account_id == account.account_id
  end

  defp compress_public_key(<<_prefix, x::binary-size(32), y::binary-size(32)>>) do
    prefix = if rem(:binary.last(y), 2) == 1, do: 3, else: 2
    <<prefix, x::binary>>
  end
end
