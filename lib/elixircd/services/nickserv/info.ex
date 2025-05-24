defmodule ElixIRCd.Services.Nickserv.Info do
  @moduledoc """
  Module for the NickServ INFO command.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv, only: [notify: 2]
  import ElixIRCd.Utils.Protocol, only: [irc_operator?: 1]

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["INFO", target_nick | _command_params]) do
    case RegisteredNicks.get_by_nickname(target_nick) do
      {:ok, registered_nick} ->
        has_full_access = user.identified_as == registered_nick.nickname || irc_operator?(user)
        show_info(user, registered_nick, has_full_access)

      {:error, :registered_nick_not_found} ->
        notify(user, "Nick \x02#{target_nick}\x02 is not registered.")
    end
  end

  def handle(user, ["INFO"]) do
    handle(user, ["INFO", user.nick])
  end

  @spec show_info(User.t(), RegisteredNick.t(), boolean()) :: :ok
  defp show_info(user, registered_nick, has_full_access) do
    notify(user, "\x02\x0312*** \x0304#{registered_nick.nickname}\x0312 ***\x03\x02")

    display_online_status(user, registered_nick)

    if has_full_access do
      display_registration_info(user, registered_nick)
      display_email_info(user, registered_nick, has_full_access)
      show_options(user, registered_nick, has_full_access)
    else
      notify(user, "The information for this nickname is private.")
    end
  end

  @spec display_online_status(User.t(), RegisteredNick.t()) :: :ok
  defp display_online_status(user, registered_nick) do
    currently_used =
      case Users.get_by_nick(registered_nick.nickname) do
        {:ok, _online_user} -> true
        {:error, :user_not_found} -> false
      end

    if currently_used do
      notify(user, "\x02#{registered_nick.nickname}\x02 is currently online.")
    else
      notify(user, "\x02#{registered_nick.nickname}\x02 is not currently online.")
    end
  end

  @spec display_registration_info(User.t(), RegisteredNick.t()) :: :ok
  defp display_registration_info(user, registered_nick) do
    notify(user, "Registered on: #{format_datetime(registered_nick.created_at)}")

    case registered_nick.last_seen_at do
      nil -> notify(user, "Last seen: never")
      last_seen_at -> notify(user, "Last seen: #{format_datetime(last_seen_at)}")
    end

    notify(user, "Registered from: \x02#{registered_nick.registered_by}\x02")
  end

  @spec display_email_info(User.t(), RegisteredNick.t(), boolean()) :: :ok
  defp display_email_info(user, registered_nick, has_full_access) do
    if registered_nick.email && (!registered_nick.settings.hide_email || has_full_access) do
      notify(user, "Email address: \x02#{registered_nick.email}\x02")
    end
  end

  @spec show_options(User.t(), RegisteredNick.t(), boolean()) :: :ok
  defp show_options(user, registered_nick, has_full_access) do
    flags = []

    flags =
      if is_nil(registered_nick.verified_at) do
        flags ++ ["UNVERIFIED"]
      else
        flags
      end

    flags =
      if has_full_access && registered_nick.settings.hide_email do
        flags ++ ["HIDEMAIL"]
      else
        flags
      end

    if !Enum.empty?(flags) do
      notify(user, "Flags: \x02#{Enum.join(flags, ", ")}\x02")
    end

    :ok
  end

  @spec format_datetime(DateTime.t()) :: String.t()
  defp format_datetime(datetime) do
    iso_str = DateTime.to_iso8601(datetime)
    String.replace(iso_str, "T", " ")
  end
end
