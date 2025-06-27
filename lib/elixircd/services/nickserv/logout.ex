defmodule ElixIRCd.Services.Nickserv.Logout do
  @moduledoc """
  Module for the NickServ LOGOUT command.
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

    updated_user = Users.update(user, %{identified_as: nil, modes: new_modes})

    Message.build(%{
      prefix: :server,
      command: "MODE",
      params: [updated_user.nick, "-r"]
    })
    |> Dispatcher.broadcast(updated_user)

    notify(updated_user, "You are now logged out from \x02#{identified_nickname}\x02.")
  end
end
