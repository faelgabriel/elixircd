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
      notify: 2
    ]

  alias ElixIRCd.Repositories.NickAccesses
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.RegisteredNick
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
        cleanup_channel_registrations(registered_nick.account_name)
      end

      RegisteredNicks.delete(cleared_nickname)

      notify(user, "Nick \x02#{registered_nick.nickname}\x02 has been dropped.")
    end
  end

  @spec verify_drop_account_password(User.t(), RegisteredNick.t(), String.t()) :: :ok
  defp verify_drop_account_password(user, registered_nick, password) do
    case get_account_nick(registered_nick) do
      {:ok, account_nick} ->
        if Argon2.verify_pass(password, account_nick.password_hash) do
          drop_nickname(user, registered_nick)
        else
          notify(user, "Authentication failed. Invalid password for \x02#{registered_nick.nickname}\x02.")
        end

      {:error, :registered_nick_not_found} ->
        notify(user, "Nick \x02#{registered_nick.nickname}\x02 is not registered.")
    end
  end
end
