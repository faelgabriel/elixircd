defmodule ElixIRCd.Services.Nickserv.Resetpass do
  @moduledoc "Email-based, single-use password recovery for verified NickServ accounts."

  @behaviour ElixIRCd.Service

  require Logger

  import ElixIRCd.Utils.Nickserv, only: [notify: 2, secure_connection?: 1]

  alias ElixIRCd.Accounts.Credentials
  alias ElixIRCd.Observability
  alias ElixIRCd.Repositories.PasswordResets
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.PasswordReset
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Mailer

  @ttl_seconds 1800
  @request_interval_seconds 300
  @generic "If that account has a verified email address, recovery instructions will be sent."

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["RESETPASS", "CONFIRM", nickname, code, new_password]) do
    if secure_connection?(user),
      do: complete(user, nickname, code, new_password),
      else: notify(user, "A secure TLS connection is required to reset a password.")
  end

  def handle(user, ["RESETPASS", nickname]) do
    request(nickname)
    notify(user, @generic)
  end

  def handle(user, ["RESETPASS" | _]) do
    notify(user, "Syntax: \x02RESETPASS <nickname>\x02 or \x02RESETPASS CONFIRM <nickname> <code> <new-password>\x02")
  end

  defp request(nickname) do
    with {:ok, registered_nick} <- RegisteredNicks.get_by_nickname(nickname),
         {:ok, account} <- RegisteredNicks.get_by_nickname(registered_nick.account_name),
         true <- is_binary(account.email) and not is_nil(account.verified_at) do
      code = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
      now = DateTime.utc_now()
      reset = PasswordReset.new(account.account_name, Credentials.code_hash(code), now, DateTime.add(now, @ttl_seconds))

      stored? = Memento.transaction!(fn -> store_if_ready(reset) end)

      maybe_schedule_delivery(stored?, account.email, account.account_name, code, reset)
    else
      _ -> :ok
    end
  end

  defp store_if_ready(reset) do
    if ready?(reset.account_name_key) do
      PasswordResets.put(reset)
      true
    else
      false
    end
  end

  defp maybe_schedule_delivery(true, email, account_name, code, reset),
    do: Observability.defer_effect(fn -> deliver(email, account_name, code, reset) end)

  defp maybe_schedule_delivery(false, _email, _account_name, _code, _reset), do: :ok

  defp deliver(email, account_name, code, reset) do
    case send_reset_email(email, account_name, code) do
      {:ok, _email} ->
        :ok

      {:error, _reason} ->
        remove_failed_reset(account_name, reset)
    end
  end

  defp send_reset_email(email, account_name, code) do
    Mailer.send_password_reset_email(email, account_name, code)
  rescue
    _error ->
      Logger.warning("NickServ password reset email delivery failed")
      {:error, :delivery_failed}
  end

  defp remove_failed_reset(account_name, reset) do
    Memento.transaction!(fn ->
      case PasswordResets.get(account_name, lock: :write) do
        %{code_hash: code_hash} when code_hash == reset.code_hash -> PasswordResets.delete(account_name)
        _ -> :ok
      end
    end)
  end

  defp ready?(account_name) do
    case PasswordResets.get(account_name, lock: :write) do
      nil -> true
      reset -> DateTime.diff(DateTime.utc_now(), reset.requested_at) >= @request_interval_seconds
    end
  end

  defp complete(user, nickname, code, new_password) do
    result =
      case RegisteredNicks.get_by_nickname(nickname) do
        {:ok, registered_nick} -> Credentials.reset(registered_nick.account_name, code, new_password)
        _ -> {:error, :invalid_code}
      end

    case result do
      :ok -> notify(user, "Your password has been reset. Identify again with the new password.")
      {:error, :short_password} -> notify(user, "The new password is too short.")
      _ -> notify(user, "Invalid or expired password reset code.")
    end
  end
end
