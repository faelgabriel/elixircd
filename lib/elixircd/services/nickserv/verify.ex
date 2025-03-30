defmodule ElixIRCd.Services.Nickserv.Verify do
  @moduledoc """
  Module for the NickServ verify command.
  """

  @behaviour ElixIRCd.Service

  require Logger

  import ElixIRCd.Utils.Nickserv, only: [send_notice: 2]
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["VERIFY", nickname, code]) do
    verify_nickname(user, nickname, code)
    :ok
  end

  def handle(user, ["VERIFY" | _rest_params]) do
    send_notice(user, "Insufficient parameters for \x02VERIFY\x02.")
    send_notice(user, "Syntax: \x02VERIFY <nickname> <code>\x02")
    :ok
  end

  @spec verify_nickname(User.t(), String.t(), String.t()) :: :ok
  defp verify_nickname(user, nickname, code) do
    case RegisteredNicks.get_by_nickname(nickname) do
      {:ok, reg_nick} ->
        verify_code_and_state(user, reg_nick, code)

      {:error, _} ->
        send_notice(user, "Nickname \x02#{nickname}\x02 is not registered.")
    end
  end

  @spec verify_code_and_state(User.t(), ElixIRCd.Tables.RegisteredNick.t(), String.t()) :: :ok
  defp verify_code_and_state(user, reg_nick, code) do
    cond do
      !is_nil(reg_nick.verified_at) ->
        send_notice(user, "Nickname \x02#{reg_nick.nickname}\x02 is already verified.")

      is_nil(reg_nick.verify_code) ->
        send_notice(user, "Nickname \x02#{reg_nick.nickname}\x02 does not require verification.")

      reg_nick.verify_code != code ->
        send_notice(user, "Verification failed. Invalid code for nickname \x02#{reg_nick.nickname}\x02.")
        Logger.warning("Failed verification attempt for #{reg_nick.nickname} by #{user_mask(user)}")

      true ->
        complete_verification(user, reg_nick)
    end
  end

  @spec complete_verification(User.t(), ElixIRCd.Tables.RegisteredNick.t()) :: :ok
  defp complete_verification(user, reg_nick) do
    RegisteredNicks.update(reg_nick, %{
      verify_code: nil,
      verified_at: DateTime.utc_now(),
      last_seen_at: DateTime.utc_now()
    })

    send_notice(user, "Nickname \x02#{reg_nick.nickname}\x02 has been successfully verified.")

    # If the user is using this nickname, identify them
    if user.nick == reg_nick.nickname do
      send_notice(user, "You are now identified for \x02#{reg_nick.nickname}\x02.")
      # TODO: Set the user as identified in the system
    else
      send_notice(
        user,
        "You can now identify for this nickname using: \x02/msg NickServ IDENTIFY #{reg_nick.nickname} your_password\x02"
      )
    end

    Logger.info("Nickname verified: #{reg_nick.nickname} by #{user_mask(user)}")
  end
end
