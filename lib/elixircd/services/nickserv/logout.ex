defmodule ElixIRCd.Services.Nickserv.Logout do
  @moduledoc """
  This module defines the NickServ LOGOUT command.

  LOGOUT allows users to log out from their authenticated session.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv, only: [notify: 2]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["LOGOUT"]) do
    if user.identified_as do
      logout_user(user)
    else
      notify(user, "You are not identified to any nickname.")
    end
  end

  def handle(user, ["LOGOUT" | _command_params]) do
    notify(user, [
      "Too many parameters for \x02LOGOUT\x02.",
      "Syntax: \x02LOGOUT\x02"
    ])
  end

  @spec logout_user(User.t()) :: :ok
  defp logout_user(user) do
    identified_nickname = user.identified_as
    new_modes = List.delete(user.modes, "r")

    updated_user =
      Users.update(user, %{
        identified_as: nil,
        sasl_authenticated: false,
        modes: new_modes
      })

    %Message{command: "MODE", params: [updated_user.nick, "-r"]}
    |> Dispatcher.broadcast(:server, updated_user)

    notify(updated_user, "You are now logged out from \x02#{identified_nickname}\x02.")

    notify_account_change(updated_user)
  end

  @spec notify_account_change(User.t()) :: :ok
  defp notify_account_change(user) do
    account_notify_supported = Application.get_env(:elixircd, :capabilities)[:account_notify] || false

    if account_notify_supported do
      watchers = Users.get_in_shared_channels_with_capability(user, "ACCOUNT-NOTIFY", true)

      if watchers != [] do
        %Message{command: "ACCOUNT", params: ["*"]}
        |> Dispatcher.broadcast(user, watchers)
      end
    end

    :ok
  end
end
