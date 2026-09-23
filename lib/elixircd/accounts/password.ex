defmodule ElixIRCd.Accounts.Password do
  @moduledoc "Password verification and safe credential-upgrade helpers."

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Sasl.ScramSha256
  alias ElixIRCd.Tables.RegisteredNick

  @doc "Verifies Argon2 and lazily adds SCRAM credentials. Pending accounts are allowed only for account deletion."
  @spec verify_and_upgrade(RegisteredNick.t(), String.t(), keyword()) :: {:ok, RegisteredNick.t()} | :error
  def verify_and_upgrade(account, password, options \\ [])

  def verify_and_upgrade(%RegisteredNick{verify_code: code, verified_at: nil} = account, password, options)
      when is_binary(code) and is_binary(password) do
    if Keyword.get(options, :allow_unverified, false), do: verify_password(account, password), else: :error
  end

  def verify_and_upgrade(%RegisteredNick{} = account, password, _options) when is_binary(password) do
    verify_password(account, password)
  end

  defp verify_password(account, password) do
    if Argon2.verify_pass(password, account.password_hash) do
      {:ok, maybe_add_scram_verifier(account, password)}
    else
      :error
    end
  end

  @spec maybe_add_scram_verifier(RegisteredNick.t(), String.t()) :: RegisteredNick.t()
  defp maybe_add_scram_verifier(%{scram_sha_256: nil} = account, password) do
    case ScramSha256.configured_credentials(password) do
      nil -> account
      credentials -> RegisteredNicks.update(account, %{scram_sha_256: credentials})
    end
  end

  defp maybe_add_scram_verifier(account, _password), do: account
end
