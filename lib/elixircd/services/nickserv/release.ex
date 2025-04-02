defmodule ElixIRCd.Services.Nickserv.Release do
  @moduledoc """
  Module for the NickServ RELEASE command.
  """

  @behaviour ElixIRCd.Service

  require Logger

  import ElixIRCd.Utils.Nickserv, only: [send_notice: 2]
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["RELEASE", target_nick | rest_params]) do
    password = Enum.at(rest_params, 0)

    # Verify if the nickname is registered
    case RegisteredNicks.get_by_nickname(target_nick) do
      {:ok, registered_nick} ->
        if reserved?(registered_nick) do
          handle_reserved_nick(user, registered_nick, password)
        else
          send_notice(user, "Nick \x02#{target_nick}\x02 is not being held.")
        end

      {:error, _} ->
        send_notice(user, "Nick \x02#{target_nick}\x02 is not registered.")
    end

    :ok
  end

  def handle(user, ["RELEASE" | _rest_params]) do
    send_notice(user, "Insufficient parameters for \x02RELEASE\x02.")
    send_notice(user, "Syntax: \x02RELEASE <nickname> <password>\x02")
    :ok
  end

  @spec handle_reserved_nick(User.t(), ElixIRCd.Tables.RegisteredNick.t(), String.t() | nil) :: :ok
  defp handle_reserved_nick(user, registered_nick, password) do
    # Check if user is identified as the nickname owner
    if user.identified_as == registered_nick.nickname do
      # User is identified, no password required
      release_nickname(user, registered_nick)
    else
      # User isn't identified, verify password
      verify_password_for_release(user, registered_nick, password)
    end
  end

  @spec verify_password_for_release(User.t(), ElixIRCd.Tables.RegisteredNick.t(), String.t() | nil) :: :ok
  defp verify_password_for_release(user, registered_nick, password) do
    if is_nil(password) do
      send_notice(user, "Insufficient parameters for \x02RELEASE\x02.")
      send_notice(user, "Syntax: \x02RELEASE <nickname> <password>\x02")
    else
      if Pbkdf2.verify_pass(password, registered_nick.password_hash) do
        release_nickname(user, registered_nick)
      else
        send_notice(user, "Invalid password for \x02#{registered_nick.nickname}\x02.")
        Logger.warning("Failed RELEASE attempt for #{registered_nick.nickname} from #{user_mask(user)}")
      end
    end
  end

  @spec release_nickname(User.t(), ElixIRCd.Tables.RegisteredNick.t()) :: :ok
  defp release_nickname(user, registered_nick) do
    # Clear the reservation
    RegisteredNicks.update(registered_nick, %{reserved_until: nil})

    send_notice(user, "Nick \x02#{registered_nick.nickname}\x02 has been released.")
    Logger.info("User #{user_mask(user)} released nickname #{registered_nick.nickname}")
    :ok
  end

  @spec reserved?(ElixIRCd.Tables.RegisteredNick.t()) :: boolean()
  defp reserved?(registered_nick) do
    case registered_nick.reserved_until do
      nil -> false
      reserved_until -> DateTime.compare(reserved_until, DateTime.utc_now()) == :gt
    end
  end
end
