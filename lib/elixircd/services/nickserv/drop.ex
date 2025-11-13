defmodule ElixIRCd.Services.Nickserv.Drop do
  @moduledoc """
  This module defines the NickServ DROP command.

  DROP allows users to unregister their nicknames.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv, only: [notify: 2]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
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
    if user.identified_as == registered_nick.nickname do
      drop_nickname(user, registered_nick)
    else
      verify_password_for_drop(user, registered_nick, password)
    end
  end

  @spec verify_password_for_drop(User.t(), RegisteredNick.t(), String.t() | nil) :: :ok
  defp verify_password_for_drop(user, registered_nick, password) do
    if is_nil(password) do
      notify(user, [
        "Insufficient parameters for \x02DROP\x02.",
        "Syntax: \x02DROP <nickname> <password>\x02"
      ])
    else
      if Argon2.verify_pass(password, registered_nick.password_hash) do
        drop_nickname(user, registered_nick)
      else
        notify(user, "Authentication failed. Invalid password for \x02#{registered_nick.nickname}\x02.")
      end
    end
  end

  @spec drop_nickname(User.t(), RegisteredNick.t()) :: :ok
  defp drop_nickname(user, registered_nick) do
    cleared_nickname = RegisteredNicks.update(registered_nick, %{reserved_until: nil})

    case Users.get_by_nick(registered_nick.nickname) do
      {:ok, target_user} ->
        if target_user.identified_as == registered_nick.nickname do
          new_modes = List.delete(target_user.modes, "r")
          updated_target_user = Users.update(target_user, %{identified_as: nil, modes: new_modes})

          %Message{
            command: "MODE",
            params: [updated_target_user.nick, "-r"]
          }
          |> Dispatcher.broadcast(:server, updated_target_user)
        end

      {:error, :user_not_found} ->
        :ok
    end

    if user.identified_as == registered_nick.nickname and user.nick != registered_nick.nickname do
      new_modes = List.delete(user.modes, "r")
      updated_user = Users.update(user, %{identified_as: nil, modes: new_modes})

      %Message{
        command: "MODE",
        params: [updated_user.nick, "-r"]
      }
      |> Dispatcher.broadcast(:server, updated_user)
    end

    RegisteredNicks.delete(cleared_nickname)

    notify(user, "Nick \x02#{registered_nick.nickname}\x02 has been dropped.")
  end
end
