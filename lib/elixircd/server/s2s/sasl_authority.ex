defmodule ElixIRCd.Server.S2S.SASLAuthority do
  @moduledoc """
  Credential callbacks used only by the configured native S2S authority.

  The callbacks run in bounded SASL workers and return an opaque account ID.
  They never return a password, password hash, email address or account row.
  """

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Server.S2S.Identity
  alias ElixIRCd.Utils.Ecdsa

  @doc "Verifies a PLAIN credential against the local authority database."
  @spec plain_lookup(String.t(), String.t(), map()) :: {:ok, Identity.id()} | :error
  def plain_lookup(username, password, client_info)
      when is_binary(username) and is_binary(password) and is_map(client_info) do
    with {:ok, account} <- account_for_nickname(username),
         true <- secure_account_allowed?(account, client_info),
         true <- Argon2.verify_pass(password, account.password_hash),
         account_id when is_binary(account_id) <- account.account_id,
         true <- Identity.valid_id?(account_id) do
      {:ok, account_id}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _kind, _reason -> :error
  end

  @doc "Looks up the account public key without exporting the private account row."
  @spec ecdsa_lookup(String.t(), String.t(), map()) :: {:ok, binary(), Identity.id()} | :error
  def ecdsa_lookup(uid, account_name, client_info)
      when is_binary(uid) and is_binary(account_name) and is_map(client_info) do
    with true <- Identity.valid_id?(uid),
         {:ok, account} <- account_for_nickname(account_name),
         true <- secure_account_allowed?(account, client_info),
         {:ok, public_key} <- public_key(account.settings.pubkey),
         account_id when is_binary(account_id) <- account.account_id,
         true <- Identity.valid_id?(account_id) do
      {:ok, public_key, account_id}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _kind, _reason -> :error
  end

  def ecdsa_lookup(_uid, _account_name, _client_info), do: :error

  defp account_for_nickname(nickname) do
    Memento.transaction!(fn ->
      with {:ok, registered_nick} <- RegisteredNicks.get_by_nickname(nickname),
           {:ok, account} <- RegisteredNicks.get_by_nickname(registered_nick.account_name) do
        {:ok, account}
      end
    end)
  end

  defp secure_account_allowed?(account, %{"secure_client" => secure_client}) do
    Map.get(account.settings, :secure) != true or secure_client == true
  end

  defp secure_account_allowed?(_account, _client_info), do: false

  defp public_key(encoded) when is_binary(encoded) do
    with {:ok, key} <- Base.decode64(encoded, padding: false),
         true <- Ecdsa.valid_compressed_p256_public_key?(key) do
      {:ok, key}
    else
      _ -> :error
    end
  end

  defp public_key(_encoded), do: :error
end
