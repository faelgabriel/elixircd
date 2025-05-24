defmodule ElixIRCd.Services.Nickserv.Identify do
  @moduledoc """
  Module for the NickServ IDENTIFY command.
  """

  @behaviour ElixIRCd.Service

  require Logger

  import ElixIRCd.Utils.Nickserv, only: [notify: 2]
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["IDENTIFY", password]) when is_binary(password) do
    identify_nickname(user, user.nick, password)
    :ok
  end

  def handle(user, ["IDENTIFY", nickname, password]) do
    identify_nickname(user, nickname, password)
    :ok
  end

  def handle(user, ["IDENTIFY" | _command_params]) do
    notify(user, [
      "Insufficient parameters for \x02IDENTIFY\x02.",
      "Syntax: \x02IDENTIFY [nickname] <password>\x02"
    ])

    :ok
  end

  @spec identify_nickname(User.t(), String.t(), String.t()) :: :ok
  defp identify_nickname(user, nickname, password) do
    Logger.debug("IDENTIFY attempt for nickname #{nickname} from #{user_mask(user)}")

    if user.identified_as == nickname do
      notify(user, "You are already identified as \x02#{nickname}\x02.")
    else
      verify_nickname_and_password(user, nickname, password)
    end
  end

  @spec verify_nickname_and_password(User.t(), String.t(), String.t()) :: :ok
  defp verify_nickname_and_password(user, nickname, password) do
    case RegisteredNicks.get_by_nickname(nickname) do
      {:ok, registered_nick} ->
        verify_password(user, registered_nick, password)

      {:error, :registered_nick_not_found} ->
        notify(user, "Nickname \x02#{nickname}\x02 is not registered.")
    end
  end

  @spec verify_password(User.t(), RegisteredNick.t(), String.t()) :: :ok
  defp verify_password(user, registered_nick, password) do
    if Pbkdf2.verify_pass(password, registered_nick.password_hash) do
      complete_identification(user, registered_nick)
    else
      handle_failed_identification(user, registered_nick)
    end
  end

  @spec complete_identification(User.t(), RegisteredNick.t()) :: :ok
  defp complete_identification(user, registered_nick) do
    RegisteredNicks.update(registered_nick, %{
      last_seen_at: DateTime.utc_now()
    })

    Users.update(user, %{identified_as: registered_nick.nickname})

    notify(user, "You are now identified for \x02#{registered_nick.nickname}\x02.")

    if user.nick != registered_nick.nickname do
      notify(user, "Your current nickname will now be recognized with your account.")
    end
  end

  @spec handle_failed_identification(User.t(), RegisteredNick.t()) :: :ok
  defp handle_failed_identification(user, registered_nick) do
    notify(user, "Password incorrect for \x02#{registered_nick.nickname}\x02.")
  end
end
