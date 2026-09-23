defmodule ElixIRCd.Commands.Verify do
  @moduledoc "Completes IRCv3 account registration after email verification."

  @behaviour ElixIRCd.Command

  import ElixIRCd.Utils.Nickserv, only: [notify_account_change: 2, sync_registered_mode: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Server.NickEnforcement
  alias ElixIRCd.StandardReply

  @impl true
  def handle(user, %{params: [account, code], trailing: nil}), do: verify(user, account, code)
  def handle(user, %{params: [account], trailing: code}) when is_binary(code), do: verify(user, account, code)

  def handle(user, _message), do: fail(user, "NEED_MORE_PARAMS", "*", "VERIFY requires an account and code")

  defp verify(user, requested_account, code) do
    account = if requested_account == "*", do: user.nick, else: requested_account

    with :ok <- available(user),
         :ok <- connected(user),
         :ok <- unauthenticated(user),
         true <- is_binary(account),
         {:ok, registered_nick} <- RegisteredNicks.get_by_nickname(account),
         true <-
           is_nil(registered_nick.verified_at) and is_binary(code) and is_binary(registered_nick.verify_code) and
             byte_size(registered_nick.verify_code) == byte_size(code) and
             :crypto.hash_equals(registered_nick.verify_code, code) do
      verified =
        RegisteredNicks.update(registered_nick, %{
          verify_code: nil,
          verified_at: DateTime.utc_now(),
          last_seen_at: DateTime.utc_now()
        })

      updated_user =
        user
        |> Users.update(%{identified_as: verified.account_name})
        |> sync_registered_mode()

      NickEnforcement.schedule_enforcement(updated_user)
      notify_account_change(updated_user, verified.account_name)

      %Message{
        command: "VERIFY",
        params: ["SUCCESS", verified.account_name],
        trailing: "Account #{verified.account_name} has been verified"
      }
      |> Dispatcher.broadcast(:server, updated_user)
    else
      {:error, :unavailable} ->
        fail(user, "REGISTRATION_DISABLED", account, "Verification is unavailable")

      {:error, :not_connected} ->
        fail(user, "COMPLETE_CONNECTION_REQUIRED", nil, "Complete connection registration first")

      {:error, :already_authenticated} ->
        fail(user, "ALREADY_AUTHENTICATED", account, "Already authenticated")

      _ ->
        fail(user, "INVALID_CODE", account, "Invalid or expired verification code")
    end
  end

  defp available(user) do
    config = Application.fetch_env!(:elixircd, :account_registration)
    if config[:enabled] and "draft/account-registration" in user.capabilities, do: :ok, else: {:error, :unavailable}
  end

  defp connected(%{registered: true}), do: :ok

  defp connected(_user) do
    if Application.fetch_env!(:elixircd, :account_registration)[:before_connect],
      do: :ok,
      else: {:error, :not_connected}
  end

  defp unauthenticated(%{identified_as: account}) when is_binary(account), do: {:error, :already_authenticated}
  defp unauthenticated(_user), do: :ok

  defp fail(user, code, account, description) do
    %StandardReply{type: :fail, command: "VERIFY", code: code, context: List.wrap(account), description: description}
    |> Dispatcher.broadcast(:server, user)
  end
end
