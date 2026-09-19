defmodule ElixIRCd.Commands.Register do
  @moduledoc "Implements IRCv3 account-registration over the REGISTER command."

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Nickserv, only: [notify_account_change: 2, sync_registered_mode: 1]
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Sasl.ScramSha256
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.StandardReply
  alias ElixIRCd.Utils.CaseMapping

  @impl true
  def handle(user, %{params: [requested_account, email_parameter, password | _]}) do
    account = if requested_account == "*", do: user.nick, else: requested_account
    email = if email_parameter == "*", do: nil, else: email_parameter

    with :ok <- available(user),
         :ok <- validate_connection_state(user),
         :ok <- validate_account_name(user, account),
         :ok <- validate_email(email),
         :ok <- validate_password(password),
         {:error, :registered_nick_not_found} <- RegisteredNicks.get_by_nickname(account) do
      create_account(user, account, email, password)
    else
      {:ok, _registered_nick} -> fail(user, "ACCOUNT_EXISTS", account || "*", "Account already exists")
      {:error, reason} -> fail_reason(user, account || "*", reason)
    end
  end

  def handle(user, _message), do: fail(user, "NEED_MORE_PARAMS", "*", "REGISTER requires account, email and password")

  defp available(user) do
    config = Application.fetch_env!(:elixircd, :account_registration)

    if config[:enabled] and "draft/account-registration" in user.capabilities do
      :ok
    else
      {:error, :unavailable}
    end
  end

  defp validate_connection_state(%{registered: true}), do: :ok

  defp validate_connection_state(_user) do
    if Application.fetch_env!(:elixircd, :account_registration)[:before_connect] do
      :ok
    else
      {:error, :complete_connection_required}
    end
  end

  defp validate_account_name(%{nick: nil}, _account), do: {:error, :invalid_account_name}
  defp validate_account_name(_user, nil), do: {:error, :invalid_account_name}

  defp validate_account_name(user, account) do
    if CaseMapping.normalize(account) == CaseMapping.normalize(user.nick) do
      :ok
    else
      {:error, :account_name_must_be_nick}
    end
  end

  defp validate_email(nil) do
    if nickserv_config()[:email_required], do: {:error, :invalid_email}, else: :ok
  end

  defp validate_email(email) do
    if Regex.match?(~r/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/, email),
      do: :ok,
      else: {:error, :invalid_email}
  end

  defp validate_password(password) do
    if String.length(password) >= nickserv_config()[:min_password_length], do: :ok, else: {:error, :password_too_short}
  end

  defp create_account(user, account, email, password) do
    verify_code = if email, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    registered_nick =
      RegisteredNicks.create(%{
        nickname: account,
        password_hash: Argon2.hash_pwd_salt(password),
        scram_sha_256: ScramSha256.configured_credentials(password),
        email: email,
        registered_by: user_mask(user),
        verify_code: verify_code,
        verified_at: if(email, do: nil, else: DateTime.utc_now())
      })

    updated_user =
      user
      |> Users.update(%{identified_as: registered_nick.account_name})
      |> sync_registered_mode()

    %Message{
      command: "REGISTER",
      params: ["SUCCESS", registered_nick.account_name],
      trailing: "Account #{registered_nick.account_name} has been registered"
    }
    |> Dispatcher.broadcast(:server, updated_user)

    notify_account_change(updated_user, registered_nick.account_name)
  end

  defp fail_reason(user, account, :account_name_must_be_nick),
    do: fail(user, "ACCOUNT_NAME_MUST_BE_NICK", account, "Account name must match your nickname")

  defp fail_reason(user, account, :complete_connection_required),
    do: fail(user, "COMPLETE_CONNECTION_REQUIRED", account, "Complete connection registration first")

  defp fail_reason(user, account, :invalid_email), do: fail(user, "INVALID_EMAIL", account, "A valid email is required")

  defp fail_reason(user, account, :password_too_short),
    do: fail(user, "INVALID_PASSWORD", account, "Password is too short")

  defp fail_reason(user, account, :invalid_account_name),
    do: fail(user, "INVALID_ACCOUNT_NAME", account, "Invalid account name")

  defp fail_reason(user, account, :unavailable),
    do: fail(user, "REGISTRATION_DISABLED", account, "Account registration is unavailable")

  defp fail(user, code, account, description) do
    %StandardReply{type: :fail, command: "REGISTER", code: code, context: [account], description: description}
    |> Dispatcher.broadcast(:server, user)
  end

  defp nickserv_config, do: Application.fetch_env!(:elixircd, :services)[:nickserv]
end
