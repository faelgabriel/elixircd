defmodule ElixIRCd.Services.Nickserv.Recover do
  @moduledoc """
  Module for the NickServ RECOVER command.
  """

  @behaviour ElixIRCd.Service

  require Logger

  import ElixIRCd.Utils.Nickserv, only: [send_notice: 2]
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["RECOVER", target_nick | rest_params]) do
    password = Enum.at(rest_params, 0)

    # Verify if the nickname is registered
    case RegisteredNicks.get_by_nickname(target_nick) do
      {:ok, registered_nick} ->
        # Check if user is identified as the nickname owner
        if user.identified_as == registered_nick.nickname do
          # User is identified, no password required
          recover_nickname(user, registered_nick)
        else
          # User isn't identified, verify password
          if is_nil(password) do
            send_notice(user, "Insufficient parameters for \x02RECOVER\x02.")
            send_notice(user, "Syntax: \x02RECOVER <nickname> <password>\x02")
          else
            if Pbkdf2.verify_pass(password, registered_nick.password_hash) do
              recover_nickname(user, registered_nick)
            else
              send_notice(user, "Invalid password for \x02#{target_nick}\x02.")
              Logger.warning("Failed RECOVER attempt for #{target_nick} from #{user_mask(user)}")
            end
          end
        end

      {:error, _} ->
        send_notice(user, "Nick \x02#{target_nick}\x02 is not registered.")
    end

    :ok
  end

  def handle(user, ["RECOVER" | _rest_params]) do
    send_notice(user, "Insufficient parameters for \x02RECOVER\x02.")
    send_notice(user, "Syntax: \x02RECOVER <nickname> <password>\x02")
    :ok
  end

  @spec recover_nickname(User.t(), ElixIRCd.Tables.RegisteredNick.t()) :: :ok
  defp recover_nickname(user, registered_nick) do
    # Get reservation duration from config at runtime
    reservation_duration = get_reservation_duration()

    # Check if the target nickname is currently in use
    case Users.get_by_nick(registered_nick.nickname) do
      {:ok, target_user} ->
        # Don't allow recovering from yourself
        if user.pid == target_user.pid do
          send_notice(user, "You cannot recover your own session.")
          :ok
        else
          # Enforce the nickname change
          ghost_message = "Killed (#{user.nick} (RECOVER command used))"

          # Send disconnect message to the target user
          send(target_user.pid, {:disconnect, ghost_message})

          # Reserve the nickname
          reserve_nickname(registered_nick, reservation_duration)

          send_notice(user, "Nick \x02#{registered_nick.nickname}\x02 has been recovered.")
          send_notice(user, "The nick will be held for you for #{reservation_duration} seconds.")
          send_notice(user, "To use it, type: \x02/msg NickServ IDENTIFY #{registered_nick.nickname} <password>\x02")
          send_notice(user, "followed by: \x02/NICK #{registered_nick.nickname}\x02")

          Logger.info("User #{user_mask(user)} recovered nickname #{registered_nick.nickname}")
          :ok
        end

      {:error, :user_not_found} ->
        # Get reservation duration from config at runtime
        reservation_duration = get_reservation_duration()

        # Nick is not in use, just reserve it
        reserve_nickname(registered_nick, reservation_duration)

        send_notice(user, "Nick \x02#{registered_nick.nickname}\x02 has been recovered.")
        send_notice(user, "The nick will be held for you for #{reservation_duration} seconds.")
        send_notice(user, "To use it, type: \x02/msg NickServ IDENTIFY #{registered_nick.nickname} <password>\x02")
        send_notice(user, "followed by: \x02/NICK #{registered_nick.nickname}\x02")

        Logger.info("User #{user_mask(user)} recovered nickname #{registered_nick.nickname}")
        :ok
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
