defmodule ElixIRCd.Services.Nickserv.Drop do
  @moduledoc """
  This module defines the NickServ DROP command.

  DROP allows users to unregister their nicknames.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv,
    only: [
      belongs_to_account?: 2,
      cleanup_channel_registrations: 1,
      get_account_nick: 1,
      grouped?: 1,
      logout_account_users: 1,
      notify: 2,
      sync_registered_mode: 1,
      account_requires_secure_connection?: 1,
      secure_connection?: 1
    ]

  alias ElixIRCd.Accounts.Password
  alias ElixIRCd.Repositories.Memos
  alias ElixIRCd.Repositories.NickAccesses
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.RegisteredNick.Settings
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["DROP", target_nick | rest_params]) do
    password = Enum.at(rest_params, 0)

    case RegisteredNicks.get_by_nickname(target_nick) do
      {:ok, registered_nick} -> handle_registered_nick(user, registered_nick, password)
      {:error, :registered_nick_not_found} -> notify(user, "Nick \x02#{target_nick}\x02 is not registered.")
    end
  end

  def handle(user, ["DROP"]) do
    handle(user, ["DROP", user.nick])
  end

  @spec handle_registered_nick(User.t(), RegisteredNick.t(), String.t() | nil) :: :ok
  defp handle_registered_nick(user, registered_nick, password) do
    if belongs_to_account?(registered_nick, user.identified_as) do
      drop_nickname(user, registered_nick)
    else
      verify_password_for_drop(user, registered_nick, password)
    end
  end

  @spec verify_password_for_drop(User.t(), RegisteredNick.t(), String.t() | nil) :: :ok
  defp verify_password_for_drop(user, registered_nick, password) do
    case password do
      nil ->
        notify(user, [
          "Insufficient parameters for \x02DROP\x02.",
          "Syntax: \x02DROP <nickname> <password>\x02"
        ])

      _password ->
        verify_drop_account_password(user, registered_nick, password)
    end
  end

  @spec drop_nickname(User.t(), RegisteredNick.t()) :: :ok
  defp drop_nickname(user, registered_nick) do
    account_members = RegisteredNicks.get_by_account_name(registered_nick.account_name)
    primary_account_nick? = !grouped?(registered_nick)

    if primary_account_nick? and length(account_members) > 1 do
      notify(user, [
        "Nick \x02#{registered_nick.nickname}\x02 is the primary nickname for your account.",
        "Ungroup or drop the other nicknames in the group before dropping this one."
      ])
    else
      cleared_nickname = RegisteredNicks.update(registered_nick, %{reserved_until: nil})

      if primary_account_nick? do
        logout_account_users(registered_nick.account_name)
        NickAccesses.delete_by_account_name(registered_nick.account_name)
        Memos.delete_by_recipient(registered_nick.account_name)
        cleanup_channel_registrations(registered_nick.account_name)
      else
        clear_display_if_needed(registered_nick)
      end

      RegisteredNicks.delete(cleared_nickname)

      case Users.get_by_nick(registered_nick.nickname) do
        {:ok, current_user} -> sync_registered_mode(current_user)
        {:error, :user_not_found} -> :ok
      end

      notify(user, "Nick \x02#{registered_nick.nickname}\x02 has been dropped.")
    end
  end

  @spec clear_display_if_needed(RegisteredNick.t()) :: :ok
  defp clear_display_if_needed(registered_nick) do
    case get_account_nick(registered_nick) do
      {:ok, account_nick} when account_nick.settings.display == registered_nick.nickname ->
        RegisteredNicks.update(account_nick, %{settings: Settings.update(account_nick.settings, %{display: nil})})
        :ok

      _ ->
        :ok
    end
  end

  @spec verify_drop_account_password(User.t(), RegisteredNick.t(), String.t()) :: :ok
  defp verify_drop_account_password(user, registered_nick, password) do
    case get_account_nick(registered_nick) do
      {:ok, account_nick} ->
        cond do
          account_requires_secure_connection?(account_nick.account_name) and not secure_connection?(user) ->
            notify(user, "This account requires a secure TLS connection for password authentication.")

          match?({:ok, _}, Password.verify_and_upgrade(account_nick, password, allow_unverified: true)) ->
            drop_nickname(user, registered_nick)

          true ->
            notify(user, "Authentication failed. Invalid password for \x02#{registered_nick.nickname}\x02.")
        end

      {:error, :registered_nick_not_found} ->
        notify(user, "Nick \x02#{registered_nick.nickname}\x02 is not registered.")
    end
  end
end
