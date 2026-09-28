defmodule ElixIRCd.Services.Nickserv.Ghost do
  @moduledoc """
  This module defines the NickServ GHOST command.

  GHOST allows users to disconnect unauthorized sessions using their nickname.
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

  alias ElixIRCd.Accounts.Password
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["GHOST", target_nick | rest_params]) do
    password = Enum.at(rest_params, 0)

    case Users.get_by_nick(target_nick) do
      {:ok, target_user} -> disconnect_ghost(user, target_user, password)
      {:error, :user_not_found} -> notify(user, "Nick \x02#{target_nick}\x02 is not online.")
    end
  end

  def handle(user, ["GHOST" | _command_params]) do
    notify(user, [
      "Insufficient parameters for \x02GHOST\x02.",
      "Syntax: \x02GHOST <nick> [password]\x02"
    ])
  end

  @spec disconnect_ghost(User.t(), User.t(), String.t() | nil) :: :ok
  defp disconnect_ghost(user, target_user, password) do
    if user.pid == target_user.pid do
      notify(user, "You cannot ghost yourself.")
    else
      case RegisteredNicks.get_by_nickname(target_user.nick) do
        {:ok, registered_nick} ->
          handle_registered_ghost(user, target_user, registered_nick, password)

        {:error, :registered_nick_not_found} ->
          notify(user, "Nick \x02#{target_user.nick}\x02 is not registered.")
      end
    end
  end

  @spec handle_registered_ghost(User.t(), User.t(), RegisteredNick.t(), String.t() | nil) :: :ok
  defp handle_registered_ghost(user, target_user, registered_nick, password) do
    if belongs_to_account?(registered_nick, user.identified_as) do
      perform_disconnect(user, target_user)
    else
      verify_password_for_ghost(user, target_user, registered_nick, password)
    end
  end

  @spec verify_password_for_ghost(User.t(), User.t(), RegisteredNick.t(), String.t() | nil) :: :ok
  defp verify_password_for_ghost(user, target_user, registered_nick, password) do
    case password do
      nil ->
        notify(user, [
          "You need to provide a password to ghost \x02#{target_user.nick}\x02.",
          "Syntax: \x02GHOST #{target_user.nick} <password>\x02"
        ])

      _password ->
        verify_ghost_account_password(user, target_user, registered_nick, password)
    end
  end

  @spec verify_ghost_account_password(User.t(), User.t(), RegisteredNick.t(), String.t()) :: :ok
  defp verify_ghost_account_password(user, target_user, registered_nick, password) do
    case get_account_nick(registered_nick) do
      {:ok, account_nick} ->
        cond do
          account_requires_secure_connection?(account_nick.account_name) and not secure_connection?(user) ->
            notify(user, "This account requires a secure TLS connection for password authentication.")

          match?({:ok, _}, Password.verify_and_upgrade(account_nick, password)) ->
            perform_disconnect(user, target_user)

          true ->
            notify(user, "Invalid password for \x02#{target_user.nick}\x02.")
        end

      {:error, :registered_nick_not_found} ->
        notify(user, "Nick \x02#{target_user.nick}\x02 is not registered.")
    end
  end

  @spec perform_disconnect(User.t(), User.t()) :: :ok
  defp perform_disconnect(user, target_user) do
    ghost_message = "Killed (#{user.nick} (GHOST command used))"
    Dispatcher.disconnect(target_user, ghost_message)
    notify(user, "User \x02#{target_user.nick}\x02 has been disconnected.")
  end
end
