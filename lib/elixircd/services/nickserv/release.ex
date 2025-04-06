defmodule ElixIRCd.Services.Nickserv.Release do
  @moduledoc """
  Module for the NickServ RELEASE command.
  """

  @behaviour ElixIRCd.Service

  require Logger

  import ElixIRCd.Utils.Nickserv, only: [notify: 2]
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["RELEASE", target_nick | rest_params]) do
    password = Enum.at(rest_params, 0)

    case RegisteredNicks.get_by_nickname(target_nick) do
      {:ok, registered_nick} ->
        if reserved?(registered_nick) do
          handle_reserved_nick(user, registered_nick, password)
        else
          notify(user, "Nick \x02#{target_nick}\x02 is not being held.")
        end

      {:error, :registered_nick_not_found} ->
        notify(user, "Nick \x02#{target_nick}\x02 is not registered.")
    end
  end

  def handle(user, ["RELEASE" | _command_params]) do
    notify(user, [
      "Insufficient parameters for \x02RELEASE\x02.",
      "Syntax: \x02RELEASE <nickname> <password>\x02"
    ])
  end

  @spec handle_reserved_nick(User.t(), RegisteredNick.t(), String.t() | nil) :: :ok
  defp handle_reserved_nick(user, registered_nick, password) do
    if user.identified_as == registered_nick.nickname do
      release_nickname(user, registered_nick)
    else
      verify_password_for_release(user, registered_nick, password)
    end
  end

  @spec verify_password_for_release(User.t(), RegisteredNick.t(), String.t() | nil) :: :ok
  defp verify_password_for_release(user, registered_nick, password) do
    if is_nil(password) do
      notify(user, [
        "Insufficient parameters for \x02RELEASE\x02.",
        "Syntax: \x02RELEASE <nickname> <password>\x02"
      ])
    else
      if Pbkdf2.verify_pass(password, registered_nick.password_hash) do
        release_nickname(user, registered_nick)
      else
        notify(user, "Invalid password for \x02#{registered_nick.nickname}\x02.")
        Logger.info("Failed RELEASE attempt for #{registered_nick.nickname} from #{user_mask(user)}")
      end
    end
  end

  @spec release_nickname(User.t(), RegisteredNick.t()) :: :ok
  defp release_nickname(user, registered_nick) do
    RegisteredNicks.update(registered_nick, %{reserved_until: nil})

    notify(user, "Nick \x02#{registered_nick.nickname}\x02 has been released.")
    Logger.info("User #{user_mask(user)} released nickname #{registered_nick.nickname}")
  end

  @spec reserved?(RegisteredNick.t()) :: boolean()
  defp reserved?(registered_nick) do
    case registered_nick.reserved_until do
      nil -> false
      reserved_until -> DateTime.compare(reserved_until, DateTime.utc_now()) == :gt
    end
  end
end
