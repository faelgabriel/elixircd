defmodule ElixIRCd.Services.Nickserv.Release do
  @moduledoc """
  This module defines the NickServ RELEASE command.

  RELEASE allows users to release a held nickname reservation.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv,
    only: [
      account_requires_secure_connection?: 1,
      belongs_to_account?: 2,
      get_account_nick: 1,
      notify: 2,
      secure_connection?: 1
    ]

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["RELEASE", target_nick | rest_params]) do
    password = Enum.at(rest_params, 0)

    case RegisteredNicks.get_by_nickname(target_nick) do
      {:ok, registered_nick} ->
        if reserved?(registered_nick) do
          handle_reserved_nick(user, registered_nick, password)
        else
          notify(user, "Nick \x02#{target_nick}\x02 is not being held.")
        end

      {:error, :registered_nick_not_found} ->
        notify(user, "Nick \x02#{target_nick}\x02 is not registered.")
    end
  end

  def handle(user, ["RELEASE" | _command_params]) do
    notify(user, [
      "Insufficient parameters for \x02RELEASE\x02.",
      "Syntax: \x02RELEASE <nickname> <password>\x02"
    ])
  end

  @spec handle_reserved_nick(User.t(), RegisteredNick.t(), String.t() | nil) :: :ok
  defp handle_reserved_nick(user, registered_nick, password) do
    if belongs_to_account?(registered_nick, user.identified_as) do
      release_nickname(user, registered_nick)
    else
      verify_password_for_release(user, registered_nick, password)
    end
  end

  @spec verify_password_for_release(User.t(), RegisteredNick.t(), String.t() | nil) :: :ok
  defp verify_password_for_release(user, registered_nick, password) do
    case password do
      nil ->
        notify(user, [
          "Insufficient parameters for \x02RELEASE\x02.",
          "Syntax: \x02RELEASE <nickname> <password>\x02"
        ])

      _password ->
        verify_release_account_password(user, registered_nick, password)
    end
  end

  @spec verify_release_account_password(User.t(), RegisteredNick.t(), String.t()) :: :ok
  defp verify_release_account_password(user, registered_nick, password) do
    case get_account_nick(registered_nick) do
      {:ok, account_nick} ->
        cond do
          account_requires_secure_connection?(account_nick.account_name) and not secure_connection?(user) ->
            notify(user, "This account requires a secure TLS connection for password authentication.")

          Argon2.verify_pass(password, account_nick.password_hash) ->
            release_nickname(user, registered_nick)

          true ->
            notify(user, "Invalid password for \x02#{registered_nick.nickname}\x02.")
        end

      {:error, :registered_nick_not_found} ->
        notify(user, "Nick \x02#{registered_nick.nickname}\x02 is not registered.")
    end
  end

  @spec release_nickname(User.t(), RegisteredNick.t()) :: :ok
  defp release_nickname(user, registered_nick) do
    RegisteredNicks.update(registered_nick, %{reserved_until: nil})

    notify(user, "Nick \x02#{registered_nick.nickname}\x02 has been released.")
  end

  @spec reserved?(RegisteredNick.t()) :: boolean()
  defp reserved?(registered_nick) do
    case registered_nick.reserved_until do
      nil -> false
      reserved_until -> DateTime.compare(reserved_until, DateTime.utc_now()) == :gt
    end
  end
end
