defmodule ElixIRCd.Services.Nickserv.Info do
  @moduledoc """
  This module defines the NickServ INFO command.

  INFO displays information about registered nicknames.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Nickserv,
    only: [account_display_name: 1, belongs_to_account?: 2, get_account_nick: 1, notify: 2]

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
        case get_account_nick(registered_nick) do
          {:ok, account_nick} ->
            has_full_access = belongs_to_account?(registered_nick, user.identified_as) || irc_operator?(user)

            show_info(user, registered_nick, account_nick, has_full_access)

          {:error, :registered_nick_not_found} ->
            notify(user, "Nick \x02#{target_nick}\x02 is not registered.")
        end

      {:error, :registered_nick_not_found} ->
        notify(user, "Nick \x02#{target_nick}\x02 is not registered.")
    end
  end

  def handle(user, ["INFO"]) do
    handle(user, ["INFO", user.nick])
  end

  @spec show_info(User.t(), RegisteredNick.t(), RegisteredNick.t(), boolean()) :: :ok
  defp show_info(user, registered_nick, account_nick, has_full_access) do
    notify(user, "\x02\x0312*** \x0304#{registered_nick.nickname}\x0312 ***\x03\x02")

    viewer_is_owner? = belongs_to_account?(registered_nick, user.identified_as)
    display_online_status(user, registered_nick, account_nick, has_full_access)

    if has_full_access do
      display_registration_info(user, registered_nick, account_nick, viewer_is_owner?)
      display_email_info(user, account_nick, has_full_access)
      display_account_settings(user, account_nick, viewer_is_owner?)
      show_options(user, account_nick)
    else
      notify(user, "The information for this nickname is private.")
    end
  end

  @spec display_online_status(User.t(), RegisteredNick.t(), RegisteredNick.t(), boolean()) :: :ok
  defp display_online_status(user, registered_nick, account_nick, has_full_access) do
    currently_used =
      case Users.get_by_nick(registered_nick.nickname) do
        {:ok, _online_user} -> true
        {:error, :user_not_found} -> false
      end

    if setting(account_nick.settings, :hide_status, false) == true and not has_full_access do
      notify(user, "Online status is private.")
    else
      if currently_used do
        notify(user, "\x02#{registered_nick.nickname}\x02 is currently online.")
      else
        notify(user, "\x02#{registered_nick.nickname}\x02 is not currently online.")
      end
    end
  end

  @spec display_registration_info(User.t(), RegisteredNick.t(), RegisteredNick.t(), boolean()) :: :ok
  defp display_registration_info(user, registered_nick, account_nick, can_view_private?) do
    notify(user, "Registered on: #{format_datetime(registered_nick.created_at)}")

    if setting(account_nick.settings, :hide_quit, false) != true or can_view_private? do
      case registered_nick.last_seen_at do
        nil -> notify(user, "Last seen: never")
        last_seen_at -> notify(user, "Last seen: #{format_datetime(last_seen_at)}")
      end
    else
      notify(user, "Last seen information is private.")
    end

    if setting(account_nick.settings, :hide_usermask, false) != true or can_view_private? do
      notify(user, "Registered from: \x02#{registered_nick.registered_by}\x02")
    else
      notify(user, "Registration mask is private.")
    end

    if registered_nick.nickname_key != registered_nick.account_name_key do
      notify(user, "Grouped with: \x02#{registered_nick.account_name}\x02")
    end
  end

  @spec display_account_settings(User.t(), RegisteredNick.t(), boolean()) :: :ok
  defp display_account_settings(user, registered_nick, viewer_is_owner?) do
    display_name = account_display_name(registered_nick)

    if display_name != registered_nick.account_name do
      notify(user, "Display name: \x02#{display_name}\x02")
    end

    if url = setting(registered_nick.settings, :url, nil) do
      notify(user, "URL: \x02#{url}\x02")
    end

    properties = setting(registered_nick.settings, :property, %{})

    if viewer_is_owner? and properties != %{} do
      notify(user, "Properties: \x02#{map_size(properties)}\x02")
    end

    :ok
  end

  @spec display_email_info(User.t(), RegisteredNick.t(), boolean()) :: :ok
  defp display_email_info(user, registered_nick, has_full_access) do
    if registered_nick.email && (setting(registered_nick.settings, :hide_email, false) != true || has_full_access) do
      notify(user, "Email address: \x02#{registered_nick.email}\x02")
    end
  end

  @spec show_options(User.t(), RegisteredNick.t()) :: :ok
  defp show_options(user, registered_nick) do
    flags = []

    flags =
      if is_nil(registered_nick.verified_at) do
        flags ++ ["UNVERIFIED"]
      else
        flags
      end

    flags = add_flag(flags, setting(registered_nick.settings, :hide_email, false), "HIDEMAIL")
    flags = add_flag(flags, setting(registered_nick.settings, :hide_status, false), "HIDESTATUS")
    flags = add_flag(flags, setting(registered_nick.settings, :hide_usermask, false), "HIDEUSERMASK")
    flags = add_flag(flags, setting(registered_nick.settings, :hide_quit, false), "HIDEQUIT")
    flags = add_flag(flags, setting(registered_nick.settings, :enforce, false), "ENFORCE")
    flags = add_flag(flags, setting(registered_nick.settings, :never_group, false), "NEVERGROUP")
    flags = add_flag(flags, setting(registered_nick.settings, :never_op, false), "NEVEROP")
    flags = add_flag(flags, setting(registered_nick.settings, :no_greet, false), "NOGREET")
    flags = add_flag(flags, setting(registered_nick.settings, :private, false), "PRIVATE")
    flags = add_flag(flags, setting(registered_nick.settings, :quiet_chg, false), "QUIETCHG")
    flags = add_flag(flags, setting(registered_nick.settings, :secure, false), "SECURE")

    flags =
      if setting(registered_nick.settings, :msg, false) == true,
        do: flags ++ ["MSG"],
        else: flags

    email_memos = setting(registered_nick.settings, :email_memos, :off)

    flags =
      if email_memos != :off,
        do: flags ++ ["EMAILMEMOS=#{String.upcase(to_string(email_memos))}"],
        else: flags

    kill = setting(registered_nick.settings, :kill, :off)

    flags =
      if kill != :off,
        do: flags ++ ["KILL=#{String.upcase(to_string(kill))}"],
        else: flags

    if !Enum.empty?(flags) do
      notify(user, "Flags: \x02#{Enum.join(flags, ", ")}\x02")
    end

    :ok
  end

  @spec add_flag([String.t()], boolean(), String.t()) :: [String.t()]
  defp add_flag(flags, true, name), do: flags ++ [name]
  defp add_flag(flags, _enabled, _name), do: flags

  @spec setting(map(), atom(), term()) :: term()
  defp setting(settings, key, default), do: Map.get(settings, key, default) || default

  @spec format_datetime(DateTime.t()) :: String.t()
  defp format_datetime(datetime) do
    iso_str = DateTime.to_iso8601(datetime)
    String.replace(iso_str, "T", " ")
  end
end
