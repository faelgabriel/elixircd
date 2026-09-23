defmodule ElixIRCd.Services.Nickserv.Verify do
  @moduledoc """
  This module defines the NickServ VERIFY command.

  VERIFY allows users to complete the verification process for their registered nickname.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv,
    only: [notify: 2, notify_account_change: 2, pending_email_active?: 1, sync_registered_mode: 1]

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.NickEnforcement
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.CaseMapping

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["VERIFY", nickname, code]) do
    verify_nickname(user, nickname, code)
  end

  def handle(user, ["VERIFY" | _command_params]) do
    notify(user, [
      "Insufficient parameters for \x02VERIFY\x02.",
      "Syntax: \x02VERIFY <nickname> <code>\x02"
    ])
  end

  @spec verify_nickname(User.t(), String.t(), String.t()) :: :ok
  defp verify_nickname(user, nickname, code) do
    case RegisteredNicks.get_by_nickname(nickname) do
      {:ok, registered_nick} -> verify_code_and_state(user, registered_nick, code)
      {:error, :registered_nick_not_found} -> notify(user, "Nickname \x02#{nickname}\x02 is not registered.")
    end
  end

  @spec verify_code_and_state(User.t(), RegisteredNick.t(), String.t()) :: :ok
  defp verify_code_and_state(user, registered_nick, code) do
    cond do
      is_binary(registered_nick.pending_email_verify_code) and not pending_email_active?(registered_nick) ->
        expire_pending_email(user, registered_nick)

      is_binary(registered_nick.pending_email_verify_code) ->
        if registered_nick.pending_email_verify_code == code do
          complete_pending_email(user, registered_nick)
        else
          notify(user, "Verification failed. Invalid code for nickname \x02#{registered_nick.nickname}\x02.")
        end

      !is_nil(registered_nick.verified_at) ->
        notify(user, "Nickname \x02#{registered_nick.nickname}\x02 is already verified.")

      is_nil(registered_nick.verify_code) ->
        notify(user, "Nickname \x02#{registered_nick.nickname}\x02 does not require verification.")

      registered_nick.verify_code != code ->
        notify(user, "Verification failed. Invalid code for nickname \x02#{registered_nick.nickname}\x02.")

      true ->
        complete_verification(user, registered_nick)
    end
  end

  @spec expire_pending_email(User.t(), RegisteredNick.t()) :: :ok
  defp expire_pending_email(user, registered_nick) do
    RegisteredNicks.update(registered_nick, %{
      pending_email: nil,
      pending_email_verify_code: nil,
      pending_email_requested_at: nil
    })

    notify(user, "The pending email change for nickname \x02#{registered_nick.nickname}\x02 has expired.")
  end

  @spec complete_verification(User.t(), RegisteredNick.t()) :: :ok
  defp complete_verification(user, registered_nick) do
    registered_nick =
      RegisteredNicks.update(registered_nick, %{
        verify_code: nil,
        verified_at: DateTime.utc_now(),
        last_seen_at: DateTime.utc_now()
      })

    notify(user, "Nickname \x02#{registered_nick.nickname}\x02 has been successfully verified.")

    # Nick comparison is case-insensitive, like everywhere else on IRC.
    if CaseMapping.normalize(user.nick) == registered_nick.nickname_key do
      identify_user(user, registered_nick)
    else
      notify(
        user,
        "You can now identify for this nickname using: \x02/msg NickServ IDENTIFY #{registered_nick.nickname} your_password\x02"
      )
    end
  end

  @spec complete_pending_email(User.t(), RegisteredNick.t()) :: :ok
  defp complete_pending_email(user, registered_nick) do
    updated =
      RegisteredNicks.update(registered_nick, %{
        email: registered_nick.pending_email,
        pending_email: nil,
        pending_email_verify_code: nil,
        pending_email_requested_at: nil,
        last_seen_at: DateTime.utc_now()
      })

    notify(user, "The email address for nickname \x02#{updated.nickname}\x02 has been successfully verified.")
  end

  # Mirror IDENTIFY's session effects; identified_as alone desynchronizes WHOX, WHOIS 330 and +R joins.
  @spec identify_user(User.t(), RegisteredNick.t()) :: :ok
  defp identify_user(user, registered_nick) do
    updated_user =
      Users.update(user, %{
        identified_as: registered_nick.account_name
      })

    notify(updated_user, "You are now identified for \x02#{registered_nick.account_name}\x02.")

    updated_user = sync_registered_mode(updated_user)
    NickEnforcement.schedule_enforcement(updated_user)

    notify_account_change(updated_user, registered_nick.account_name)
  end
end
