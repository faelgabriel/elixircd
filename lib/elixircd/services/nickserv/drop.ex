defmodule ElixIRCd.Services.Nickserv.Drop do
  @moduledoc """
  Module for the NickServ DROP command.
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
  def handle(user, ["DROP", target_nick | rest_params]) do
    password = Enum.at(rest_params, 0)

    # Check if the nickname is registered
    case RegisteredNicks.get_by_nickname(target_nick) do
      {:ok, registered_nick} ->
        # Check if user has permission to drop this nickname
        if user.identified_as == registered_nick.nickname do
          # User is identified as the nickname owner
          drop_nickname(user, registered_nick)
        else
          # User is not identified - check password
          if is_nil(password) do
            send_notice(user, "Insufficient parameters for \x02DROP\x02.")
            send_notice(user, "Syntax: \x02DROP <nickname> <password>\x02")
          else
            if Pbkdf2.verify_pass(password, registered_nick.password_hash) do
              drop_nickname(user, registered_nick)
            else
              send_notice(user, "Authentication failed. Invalid password for \x02#{target_nick}\x02.")
              Logger.warning("Failed DROP attempt for #{target_nick} from #{user_mask(user)}")
            end
          end
        end

      {:error, _} ->
        send_notice(user, "Nick \x02#{target_nick}\x02 is not registered.")
    end

    :ok
  end

  def handle(user, ["DROP"]) do
    # User is attempting to drop their current nickname
    handle(user, ["DROP", user.nick])
  end

  def handle(user, ["DROP" | _rest_params]) do
    send_notice(user, "Insufficient parameters for \x02DROP\x02.")
    send_notice(user, "Syntax: \x02DROP <nickname> [password]\x02")
    :ok
  end

  @spec drop_nickname(User.t(), ElixIRCd.Tables.RegisteredNick.t()) :: :ok
  defp drop_nickname(user, registered_nick) do
    # Cancel any pending reservations by clearing the reserved_until field
    cleared_nickname = RegisteredNicks.update(registered_nick, %{reserved_until: nil})

    # Get a list of all users currently using this nickname
    # (There should only be one, but we'll handle all to be safe)
    case Users.get_by_nick(registered_nick.nickname) do
      {:ok, target_user} ->
        # If the user using this nick is identified to it, unidentify them
        if target_user.identified_as == registered_nick.nickname do
          Users.update(target_user, %{identified_as: nil})
        end

      {:error, _} ->
        # No user is currently using this nickname
        :ok
    end

    # If the requester is identified as this nickname, unidentify them as well
    if user.identified_as == registered_nick.nickname do
      Users.update(user, %{identified_as: nil})
    end

    # Delete the nickname registration
    RegisteredNicks.delete(cleared_nickname)

    send_notice(user, "Nick \x02#{registered_nick.nickname}\x02 has been dropped.")
    Logger.info("User #{user_mask(user)} dropped nickname #{registered_nick.nickname}")
    :ok
  end
end
