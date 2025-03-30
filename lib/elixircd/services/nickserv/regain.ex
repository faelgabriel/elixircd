defmodule ElixIRCd.Services.Nickserv.Regain do
  @moduledoc """
  Module for the NickServ REGAIN command.
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
  def handle(user, ["REGAIN", target_nick | rest_params]) do
    password = Enum.at(rest_params, 0)

    # Verify if the nickname is registered
    case RegisteredNicks.get_by_nickname(target_nick) do
      {:ok, registered_nick} ->
        # Check if user is identified as the nickname owner
        if user.identified_as == registered_nick.nickname do
          # User is identified, no password required
          regain_nickname(user, registered_nick)
        else
          # User isn't identified, verify password
          if is_nil(password) do
            send_notice(user, "Insufficient parameters for \x02REGAIN\x02.")
            send_notice(user, "Syntax: \x02REGAIN <nickname> <password>\x02")
          else
            if Pbkdf2.verify_pass(password, registered_nick.password_hash) do
              regain_nickname(user, registered_nick)
            else
              send_notice(user, "Invalid password for \x02#{target_nick}\x02.")
              Logger.warning("Failed REGAIN attempt for #{target_nick} from #{user_mask(user)}")
            end
          end
        end

      {:error, _} ->
        send_notice(user, "Nick \x02#{target_nick}\x02 is not registered.")
    end

    :ok
  end

  def handle(user, ["REGAIN" | _rest_params]) do
    send_notice(user, "Insufficient parameters for \x02REGAIN\x02.")
    send_notice(user, "Syntax: \x02REGAIN <nickname> <password>\x02")
    :ok
  end

  @spec regain_nickname(User.t(), ElixIRCd.Tables.RegisteredNick.t()) :: :ok
  defp regain_nickname(user, registered_nick) do
    # Check if the target nickname is currently in use
    case Users.get_by_nick(registered_nick.nickname) do
      {:ok, target_user} ->
        # Don't allow regaining from yourself
        if user.pid == target_user.pid do
          send_notice(user, "You cannot regain your own session.")
          :ok
        else
          # Enforce the nickname change
          ghost_message = "Killed (#{user.nick} (REGAIN command used))"

          # Send disconnect message to the target user
          send(target_user.pid, {:disconnect, ghost_message})

          # Hold the nickname for this user to use
          reserve_nickname(registered_nick)

          # Try to immediately change the user's nickname if they didn't specify a specific nick
          handle_immediate_nick_change(user, registered_nick)

          # In Atheme, REGAIN combines GHOST + a nick change in one command
          send_notice(user, "Nick \x02#{registered_nick.nickname}\x02 has been regained.")

          Logger.info("User #{user_mask(user)} regained nickname #{registered_nick.nickname}")
          :ok
        end

      {:error, :user_not_found} ->
        # Nick is not in use, just change the user's nick
        handle_immediate_nick_change(user, registered_nick)

        send_notice(user, "You have regained the nickname \x02#{registered_nick.nickname}\x02.")
        Logger.info("User #{user_mask(user)} regained nickname #{registered_nick.nickname}")
        :ok
    end
  end

  @spec handle_immediate_nick_change(User.t(), ElixIRCd.Tables.RegisteredNick.t()) :: :ok
  defp handle_immediate_nick_change(user, registered_nick) do
    # For Atheme compatibility, automatically change the user's nick if they're identified
    if user.identified_as == registered_nick.nickname do
      # Change the user's nickname immediately
      # We're sending a raw NICK command through the user's process
      # This will be processed by the normal NICK command handler
      send(user.pid, {:raw_command, "NICK #{registered_nick.nickname}"})
    end
    :ok
  end

  @spec reserve_nickname(ElixIRCd.Tables.RegisteredNick.t()) :: ElixIRCd.Tables.RegisteredNick.t()
  defp reserve_nickname(registered_nick) do
    # Get reservation duration from config at runtime
    reservation_duration = Application.get_env(:elixircd, :services)[:nickserv][:regain_reservation_duration] || 60

    reserved_until = DateTime.add(DateTime.utc_now(), reservation_duration, :second)
    RegisteredNicks.update(registered_nick, %{reserved_until: reserved_until})
  end
end
