defmodule ElixIRCd.Services.Nickserv.Ungroup do
  @moduledoc """
  This module defines the NickServ UNGROUP command.

  UNGROUP removes the current nickname from the account group and promotes it
  to an independent NickServ account. Unlike Atheme/Anope which simply unregisters
  the alias, this implementation preserves the nick registration by inheriting the
  account's password, email, and settings. The user's session is transferred to
  the new independent account.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv,
    only: [belongs_to_account?: 2, grouped?: 1, notify: 2, notify_account_change: 2]

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, ["UNGROUP" | _]) do
    notify(user, [
      "You must identify to NickServ before using the UNGROUP command.",
      "Use \x02/msg NickServ IDENTIFY <password>\x02 to identify."
    ])
  end

  def handle(user, ["UNGROUP"]) do
    with {:nick, {:ok, registered_nick}} <- {:nick, RegisteredNicks.get_by_nickname(user.nick)},
         {:account, {:ok, account_nick}} <- {:account, RegisteredNicks.get_by_nickname(user.identified_as)} do
      ungroup_current_nick(user, registered_nick, account_nick)
    else
      {:nick, {:error, :registered_nick_not_found}} ->
        notify(user, "Nick \x02#{user.nick}\x02 is not registered.")

      {:account, {:error, :registered_nick_not_found}} ->
        notify(user, "Your account could not be resolved. Please try identifying again.")
    end
  end

  def handle(user, ["UNGROUP" | _]) do
    notify(user, [
      "Too many parameters for \x02UNGROUP\x02.",
      "Syntax: \x02UNGROUP\x02"
    ])
  end

  @spec ungroup_current_nick(User.t(), RegisteredNick.t(), RegisteredNick.t()) :: :ok
  defp ungroup_current_nick(user, registered_nick, account_nick) do
    cond do
      not is_nil(account_nick.verify_code) ->
        notify(user, [
          "Your account \x02#{account_nick.account_name}\x02 has not been verified yet.",
          "Please verify it first with \x02/msg NickServ VERIFY #{account_nick.nickname} <code>\x02"
        ])

      !belongs_to_account?(registered_nick, user.identified_as) ->
        notify(user, "Nick \x02#{registered_nick.nickname}\x02 does not belong to your account.")

      !grouped?(registered_nick) ->
        notify(user, "You cannot ungroup the primary nickname of your account.")

      true ->
        detached_nick =
          RegisteredNicks.update(registered_nick, %{
            account_name: registered_nick.nickname,
            password_hash: account_nick.password_hash,
            email: account_nick.email,
            verify_code: nil,
            verified_at: account_nick.verified_at,
            last_seen_at: DateTime.utc_now(),
            settings: account_nick.settings
          })

        updated_user =
          Users.update(user, %{
            identified_as: detached_nick.account_name,
            sasl_authenticated: false
          })

        notify(updated_user, [
          "Nick \x02#{registered_nick.nickname}\x02 has been removed from account \x02#{account_nick.account_name}\x02.",
          "It is now a separate NickServ account.",
          "Your current session is now identified for \x02#{detached_nick.account_name}\x02."
        ])

        notify_account_change(updated_user, detached_nick.account_name)
    end
  end
end
