defmodule ElixIRCd.Services.Nickserv.Verify do
  @moduledoc """
  Module for the NickServ verify command.
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
  def handle(user, ["VERIFY", nickname, code]) do
    verify_nickname(user, nickname, code)
  end

  def handle(user, ["VERIFY" | _command_params]) do
    notify(user, [
      "Insufficient parameters for \x02VERIFY\x02.",
      "Syntax: \x02VERIFY <nickname> <code>\x02"
    ])
  end

  @spec verify_nickname(User.t(), String.t(), String.t()) :: :ok
  defp verify_nickname(user, nickname, code) do
    case RegisteredNicks.get_by_nickname(nickname) do
      {:ok, registered_nick} -> verify_code_and_state(user, registered_nick, code)
      {:error, :registered_nick_not_found} -> notify(user, "Nickname \x02#{nickname}\x02 is not registered.")
    end
  end

  @spec verify_code_and_state(User.t(), RegisteredNick.t(), String.t()) :: :ok
  defp verify_code_and_state(user, registered_nick, code) do
    cond do
      !is_nil(registered_nick.verified_at) ->
        notify(user, "Nickname \x02#{registered_nick.nickname}\x02 is already verified.")

      is_nil(registered_nick.verify_code) ->
        notify(user, "Nickname \x02#{registered_nick.nickname}\x02 does not require verification.")

      registered_nick.verify_code != code ->
        notify(user, "Verification failed. Invalid code for nickname \x02#{registered_nick.nickname}\x02.")
        Logger.info("Failed verification attempt for #{registered_nick.nickname} by #{user_mask(user)}")

      true ->
        complete_verification(user, registered_nick)
    end
  end

  @spec complete_verification(User.t(), RegisteredNick.t()) :: :ok
  defp complete_verification(user, registered_nick) do
    registered_nick =
      RegisteredNicks.update(registered_nick, %{
        verify_code: nil,
        verified_at: DateTime.utc_now(),
        last_seen_at: DateTime.utc_now()
      })

    notify(user, "Nickname \x02#{registered_nick.nickname}\x02 has been successfully verified.")

    if user.nick == registered_nick.nickname do
      Users.update(user, %{identified_as: registered_nick.nickname})
      notify(user, "You are now identified for \x02#{registered_nick.nickname}\x02.")
    else
      notify(
        user,
        "You can now identify for this nickname using: \x02/msg NickServ IDENTIFY #{registered_nick.nickname} your_password\x02"
      )
    end

    Logger.info("Nickname verified: #{registered_nick.nickname} by #{user_mask(user)}")
  end
end
