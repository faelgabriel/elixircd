defmodule ElixIRCd.Services.Nickserv.Info do
  @moduledoc """
  Module for the NickServ INFO command.
  """

  @behaviour ElixIRCd.Service

  require Logger

  import ElixIRCd.Utils.Nickserv, only: [send_notice: 2]
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1, irc_operator?: 1]

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["INFO", target_nick | _rest_params]) do
    case RegisteredNicks.get_by_nickname(target_nick) do
      {:ok, registered_nick} ->
        show_full_info = user.identified_as == registered_nick.nickname || irc_operator?(user)
        show_info(user, registered_nick, show_full_info)

      {:error, _} ->
        send_notice(user, "Nick \x02#{target_nick}\x02 is not registered.")
    end

    :ok
  end

  def handle(user, ["INFO"]) do
    handle(user, ["INFO", user.nick])
  end

  def handle(user, ["INFO" | _rest_params]) do
    send_notice(user, "Insufficient parameters for \x02INFO\x02.")
    send_notice(user, "Syntax: \x02INFO <nickname>\x02")
    :ok
  end

  @spec show_info(User.t(), ElixIRCd.Tables.RegisteredNick.t(), boolean()) :: :ok
  defp show_info(user, registered_nick, show_full_info) do
    send_notice(user, "\x02\x0312*** \x0304#{registered_nick.nickname}\x0312 ***\x03\x02")

    display_online_status(user, registered_nick)

    # Only show registration info and options if full info is allowed
    if show_full_info do
      display_registration_info(user, registered_nick)
      display_email_info(user, registered_nick, show_full_info)
      show_options(user, registered_nick, show_full_info)
    else
      send_notice(user, "The information for this nickname is private.")
    end

    Logger.info("User #{user_mask(user)} requested INFO for #{registered_nick.nickname}")
    :ok
  end

  @spec display_online_status(User.t(), ElixIRCd.Tables.RegisteredNick.t()) :: :ok
  defp display_online_status(user, registered_nick) do
    currently_used =
      case Users.get_by_nick(registered_nick.nickname) do
        {:ok, _} -> true
        {:error, _} -> false
      end

    if currently_used do
      send_notice(user, "\x02#{registered_nick.nickname}\x02 is currently online.")
    else
      send_notice(user, "\x02#{registered_nick.nickname}\x02 is not currently online.")
    end

    :ok
  end

  @spec display_registration_info(User.t(), ElixIRCd.Tables.RegisteredNick.t()) :: :ok
  defp display_registration_info(user, registered_nick) do
    send_notice(user, "Registered on: #{format_datetime(registered_nick.created_at)}")

    case registered_nick.last_seen_at do
      nil ->
        send_notice(user, "Last seen: never")

      last_seen_at ->
        last_seen_str = format_datetime(last_seen_at)
        send_notice(user, "Last seen: #{last_seen_str}")
    end

    send_notice(user, "Registered from: \x02#{registered_nick.registered_by}\x02")

    :ok
  end

  @spec display_email_info(User.t(), ElixIRCd.Tables.RegisteredNick.t(), boolean()) :: :ok
  defp display_email_info(user, registered_nick, show_full_info) do
    should_show_email =
      show_full_info &&
        registered_nick.email &&
        (!registered_nick.settings.hide_email ||
           user.identified_as == registered_nick.nickname ||
           irc_operator?(user))

    if should_show_email do
      send_notice(user, "Email address: \x02#{registered_nick.email}\x02")
    end

    :ok
  end

  @spec show_options(User.t(), ElixIRCd.Tables.RegisteredNick.t(), boolean()) :: :ok
  defp show_options(user, registered_nick, show_full_info) do
    flags = []

    flags =
      if is_nil(registered_nick.verified_at) do
        flags ++ ["UNVERIFIED"]
      else
        flags
      end

    flags =
      if show_full_info && registered_nick.settings.hide_email do
        flags ++ ["HIDEMAIL"]
      else
        flags
      end

    unless Enum.empty?(flags) do
      send_notice(user, "Flags: \x02#{Enum.join(flags, ", ")}\x02")
    end

    :ok
  end

  @spec format_datetime(DateTime.t()) :: String.t()
  defp format_datetime(datetime) do
    iso_str = DateTime.to_iso8601(datetime)
    String.replace(iso_str, "T", " ")
  rescue
    _ -> "unknown time"
  end
end
