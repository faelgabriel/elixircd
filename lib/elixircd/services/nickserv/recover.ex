defmodule ElixIRCd.Services.Nickserv.Recover do
  @moduledoc """
  Module for the NickServ RECOVER command.
  """

  @behaviour ElixIRCd.Service

  require Logger

  import ElixIRCd.Utils.Nickserv, only: [notify: 2]
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["RECOVER", target_nick | rest_params]) do
    password = Enum.at(rest_params, 0)

    case RegisteredNicks.get_by_nickname(target_nick) do
      {:ok, registered_nick} -> handle_registered_nick(user, registered_nick, password)
      {:error, :registered_nick_not_found} -> notify(user, "Nick \x02#{target_nick}\x02 is not registered.")
    end
  end

  def handle(user, ["RECOVER" | _command_params]) do
    notify(user, [
      "Insufficient parameters for \x02RECOVER\x02.",
      "Syntax: \x02RECOVER <nickname> <password>\x02"
    ])
  end

  @spec handle_registered_nick(User.t(), ElixIRCd.Tables.RegisteredNick.t(), String.t() | nil) :: :ok
  defp handle_registered_nick(user, registered_nick, password) do
    if user.identified_as == registered_nick.nickname do
      recover_nickname(user, registered_nick)
    else
      verify_password_for_recover(user, registered_nick, password)
    end
  end

  @spec verify_password_for_recover(User.t(), ElixIRCd.Tables.RegisteredNick.t(), String.t() | nil) :: :ok
  defp verify_password_for_recover(user, registered_nick, password) do
    if is_nil(password) do
      notify(user, [
        "Insufficient parameters for \x02RECOVER\x02.",
        "Syntax: \x02RECOVER <nickname> <password>\x02"
      ])
    else
      if Pbkdf2.verify_pass(password, registered_nick.password_hash) do
        recover_nickname(user, registered_nick)
      else
        notify(user, "Invalid password for \x02#{registered_nick.nickname}\x02.")
        Logger.warning("Failed RECOVER attempt for #{registered_nick.nickname} from #{user_mask(user)}")
      end
    end
  end

  @spec recover_nickname(User.t(), ElixIRCd.Tables.RegisteredNick.t()) :: :ok
  defp recover_nickname(user, registered_nick) do
    reservation_duration = get_reservation_duration()

    case Users.get_by_nick(registered_nick.nickname) do
      {:ok, target_user} ->
        if user.pid == target_user.pid do
          notify(user, "You cannot recover your own session.")
        else
          ghost_message = "Killed (#{user.nick} (RECOVER command used))"
          send(target_user.pid, {:disconnect, ghost_message})

          reserve_nickname(registered_nick, reservation_duration)

          recovery_instructions = [
            "Nick \x02#{registered_nick.nickname}\x02 has been recovered.",
            "The nick will be held for you for #{reservation_duration} seconds.",
            "To use it, type: \x02/msg NickServ IDENTIFY #{registered_nick.nickname} <password>\x02",
            "followed by: \x02/NICK #{registered_nick.nickname}\x02"
          ]

          notify(user, recovery_instructions)
          Logger.info("User #{user_mask(user)} recovered nickname #{registered_nick.nickname}")
        end

      {:error, :user_not_found} ->
        reserve_nickname(registered_nick, reservation_duration)

        recovery_instructions = [
          "Nick \x02#{registered_nick.nickname}\x02 has been recovered.",
          "The nick will be held for you for #{reservation_duration} seconds.",
          "To use it, type: \x02/msg NickServ IDENTIFY #{registered_nick.nickname} <password>\x02",
          "followed by: \x02/NICK #{registered_nick.nickname}\x02"
        ]

        notify(user, recovery_instructions)
        Logger.info("User #{user_mask(user)} recovered nickname #{registered_nick.nickname}")
    end
  end

  @spec get_reservation_duration() :: integer()
  defp get_reservation_duration do
    Application.get_env(:elixircd, :services)[:nickserv][:recover_reservation_duration] || 60
  end

  @spec reserve_nickname(ElixIRCd.Tables.RegisteredNick.t(), integer()) :: ElixIRCd.Tables.RegisteredNick.t()
  defp reserve_nickname(registered_nick, seconds) do
    reserved_until = DateTime.add(DateTime.utc_now(), seconds, :second)
    RegisteredNicks.update(registered_nick, %{reserved_until: reserved_until})
  end
end
