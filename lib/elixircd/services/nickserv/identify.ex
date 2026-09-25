defmodule ElixIRCd.Services.Nickserv.Identify do
  @moduledoc """
  This module defines the NickServ IDENTIFY command.

  IDENTIFY allows users to authenticate with their registered nickname.
  """

  @behaviour ElixIRCd.Service

  require Logger

  import ElixIRCd.Utils.Nickserv, only: [notify: 2, notify_account_change: 2, sync_registered_mode: 1]
  alias ElixIRCd.Observability

  alias ElixIRCd.Accounts.Password
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.NickEnforcement
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["IDENTIFY", password]) when is_binary(password) do
    identify_nickname(user, user.nick, password)
    :ok
  end

  def handle(user, ["IDENTIFY", nickname, password]) do
    identify_nickname(user, nickname, password)
    :ok
  end

  def handle(user, ["IDENTIFY" | _command_params]) do
    notify(user, [
      "Insufficient parameters for \x02IDENTIFY\x02.",
      "Syntax: \x02IDENTIFY [nickname] <password>\x02"
    ])

    :ok
  end

  @spec identify_nickname(User.t(), String.t(), String.t()) :: :ok
  defp identify_nickname(user, nickname, password) do
    Logger.debug("NickServ IDENTIFY attempt", event: "authentication.attempt")

    case RegisteredNicks.get_by_nickname(nickname) do
      {:ok, registered_nick} ->
        target_account = registered_nick.account_name

        cond do
          user.sasl_authenticated && user.identified_as != nil ->
            notify(user, "You authenticated via SASL. Please /msg NickServ LOGOUT first, then IDENTIFY.")

          user.identified_as && user.identified_as != target_account ->
            notify(
              user,
              "You are already identified as \x02#{user.identified_as}\x02. Please /msg NickServ LOGOUT first."
            )

          user.identified_as == target_account ->
            notify(user, "You are already identified as \x02#{target_account}\x02.")

          true ->
            verify_password(user, registered_nick, password)
        end

      {:error, :registered_nick_not_found} ->
        handle_failed_identification(user)
    end
  end

  @spec verify_password(User.t(), RegisteredNick.t(), String.t()) :: :ok
  defp verify_password(user, registered_nick, password) do
    case RegisteredNicks.get_by_nickname(registered_nick.account_name) do
      {:ok, account_nick} ->
        verify_account_password(user, registered_nick, account_nick, password)

      {:error, :registered_nick_not_found} ->
        handle_failed_identification(user)
    end
  end

  defp verify_account_password(user, registered_nick, account_nick, password) do
    cond do
      is_binary(account_nick.verify_code) and is_nil(account_nick.verified_at) ->
        notify(user, "This account requires email verification before authentication.")

      Map.get(account_nick.settings, :secure) == true and user.transport not in [:tls, :wss] ->
        notify(user, "This account requires a secure TLS connection for authentication.")

      true ->
        complete_password_verification(user, registered_nick, account_nick, password)
    end
  end

  defp complete_password_verification(user, registered_nick, account_nick, password) do
    case Password.verify_and_upgrade(account_nick, password) do
      {:ok, upgraded_account} -> complete_identification(user, registered_nick, upgraded_account)
      :error -> handle_failed_identification(user)
    end
  end

  @spec complete_identification(User.t(), RegisteredNick.t(), RegisteredNick.t()) :: :ok
  defp complete_identification(user, _registered_nick, account_nick) do
    Observability.defer([:authentication], %{count: 1}, %{method: :nickserv, result: :success})

    RegisteredNicks.update(account_nick, %{
      last_seen_at: DateTime.utc_now()
    })

    updated_user =
      Users.update(user, %{
        identified_as: account_nick.account_name
      })

    notify(updated_user, "You are now identified for \x02#{account_nick.account_name}\x02.")

    updated_user = sync_registered_mode(updated_user)
    NickEnforcement.schedule_enforcement(updated_user)

    notify_account_change(updated_user, account_nick.account_name)
  end

  # One generic message so IDENTIFY cannot enumerate registered accounts.
  @spec handle_failed_identification(User.t()) :: :ok
  defp handle_failed_identification(user) do
    Observability.defer([:authentication], %{count: 1}, %{method: :nickserv, result: :failure})
    notify(user, "Authentication failed. Invalid nickname or password.")
  end
end
