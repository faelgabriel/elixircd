defmodule ElixIRCd.Services.Nickserv.Ghost do
  @moduledoc """
  Module for the NickServ GHOST command.
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
  def handle(user, ["GHOST", target_nick | rest_params]) do
    password = Enum.at(rest_params, 0)

    case Users.get_by_nick(target_nick) do
      {:ok, target_user} ->
        disconnect_ghost(user, target_user, password)

      {:error, :user_not_found} ->
        send_notice(user, "Nick \x02#{target_nick}\x02 is not online.")
    end

    :ok
  end

  def handle(user, ["GHOST" | _rest_params]) do
    send_notice(user, "Insufficient parameters for \x02GHOST\x02.")
    send_notice(user, "Syntax: \x02GHOST <nick> [password]\x02")
    :ok
  end

  @spec disconnect_ghost(User.t(), User.t(), String.t() | nil) :: :ok
  defp disconnect_ghost(user, target_user, password) do
    # Don't allow ghosting yourself
    if user.pid == target_user.pid do
      send_notice(user, "You cannot ghost yourself.")
      :ok
    else
      # Verify if the nickname is registered
      case RegisteredNicks.get_by_nickname(target_user.nick) do
        {:ok, registered_nick} ->
          # Check if user is identified as the nickname owner
          if user.identified_as == registered_nick.nickname do
            # User is identified, no password required
            perform_disconnect(user, target_user)
          else
            # User isn't identified, verify password if provided
            if is_nil(password) do
              send_notice(user, "You need to provide a password to ghost \x02#{target_user.nick}\x02.")
              send_notice(user, "Syntax: \x02GHOST #{target_user.nick} <password>\x02")
            else
              if Pbkdf2.verify_pass(password, registered_nick.password_hash) do
                perform_disconnect(user, target_user)
              else
                send_notice(user, "Invalid password for \x02#{target_user.nick}\x02.")
                Logger.warning("Failed GHOST attempt for #{target_user.nick} from #{user_mask(user)}")
                :ok
              end
            end
          end

        {:error, _} ->
          send_notice(user, "Nick \x02#{target_user.nick}\x02 is not registered.")
          :ok
      end
    end
  end

  @spec perform_disconnect(User.t(), User.t()) :: :ok
  defp perform_disconnect(user, target_user) do
    ghost_message = "Killed (#{user.nick} (GHOST command used))"

    # Send disconnect message to the target user
    send(target_user.pid, {:disconnect, ghost_message})

    send_notice(user, "User \x02#{target_user.nick}\x02 has been disconnected.")
    Logger.info("User #{user_mask(user)} ghosted #{user_mask(target_user)}")
    :ok
  end
end
