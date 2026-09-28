defmodule ElixIRCd.Accounts.Credentials do
  @moduledoc "Account password changes shared by NickServ SET and RESETPASS."

  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.PasswordResets
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Sasl.ScramSha256
  alias ElixIRCd.Services.Nickserv.Logout
  alias ElixIRCd.Tables.RegisteredNick

  @doc "Changes an account password after checking the current password."
  @spec change(String.t(), String.t(), String.t()) :: :ok | {:error, atom()}
  def change(account_name, old_password, new_password) do
    with :ok <- validate(new_password),
         {:ok, account} <- RegisteredNicks.get_by_nickname(account_name),
         true <- Argon2.verify_pass(old_password, account.password_hash) do
      replace(account, new_password, account.password_hash)
    else
      false -> {:error, :invalid_password}
      {:error, :registered_nick_not_found} -> {:error, :account_not_found}
      error -> error
    end
  end

  @doc "Consumes a valid reset code and replaces the account password."
  @spec reset(String.t(), binary(), String.t()) :: :ok | {:error, atom()}
  def reset(account_name, code, new_password) do
    with :ok <- validate(new_password),
         {:ok, _account} <- RegisteredNicks.get_by_nickname(account_name) do
      password_hash = Argon2.hash_pwd_salt(new_password)
      scram = ScramSha256.configured_credentials(new_password)

      result = Memento.transaction!(fn -> consume_reset(account_name, code, password_hash, scram) end)

      schedule_revocation(result, account_name)
    else
      {:error, :registered_nick_not_found} -> {:error, :invalid_code}
      error -> error
    end
  end

  @doc "Checks the configured NickServ minimum password length."
  @spec validate(String.t()) :: :ok | {:error, :short_password}
  def validate(password) do
    min_length = Application.fetch_env!(:elixircd, :services)[:nickserv][:min_password_length]
    if String.length(password) >= min_length, do: :ok, else: {:error, :short_password}
  end

  @doc "Hashes a reset code before it is stored."
  @spec code_hash(String.t()) :: binary()
  def code_hash(code), do: :crypto.hash(:sha256, code)

  defp secure_code?(expected, code) when is_binary(code) and byte_size(code) <= 128 do
    :crypto.hash_equals(expected, code_hash(code))
  end

  defp secure_code?(_expected, _code), do: false

  defp schedule_revocation(:ok, account_name) do
    Observability.defer_effect(fn -> revoke_sessions(account_name) end)
    :ok
  end

  defp schedule_revocation(error, _account_name), do: error

  defp consume_reset(account_name, code, password_hash, scram) do
    with reset when not is_nil(reset) <- PasswordResets.get(account_name, lock: :write),
         :gt <- DateTime.compare(reset.expires_at, DateTime.utc_now()),
         true <- secure_code?(reset.code_hash, code),
         {:ok, locked} <- RegisteredNicks.get_by_nickname_for_update(account_name),
         true <- locked.nickname_key == locked.account_name_key do
      update_group(locked, password_hash, scram)
      PasswordResets.delete(account_name)
      :ok
    else
      _ -> {:error, :invalid_code}
    end
  end

  defp replace(account, new_password, expected_hash) do
    password_hash = Argon2.hash_pwd_salt(new_password)
    scram = ScramSha256.configured_credentials(new_password)

    result =
      Memento.transaction!(fn ->
        with {:ok, locked} <- RegisteredNicks.get_by_nickname_for_update(account.account_name),
             true <- locked.password_hash == expected_hash do
          update_group(locked, password_hash, scram)
          PasswordResets.delete(account.account_name)
          :ok
        else
          _ -> {:error, :stale_credentials}
        end
      end)

    schedule_revocation(result, account.account_name)
  end

  @spec update_group(RegisteredNick.t(), String.t(), ScramSha256.credentials() | nil) :: :ok
  defp update_group(account, password_hash, scram) do
    account.account_name
    |> RegisteredNicks.get_by_account_name()
    |> Enum.each(&RegisteredNicks.update(&1, %{password_hash: password_hash, scram_sha_256: scram}))

    :ok
  end

  defp revoke_sessions(account_name) do
    Memento.transaction!(fn ->
      account_name
      |> Users.get_by_identified_as()
      |> Enum.each(&Logout.logout_user/1)
    end)

    :ok
  end
end
