defmodule ElixIRCd.Services.Nickserv.Set do
  @moduledoc """
  Module for the NickServ SET command.
  """

  @behaviour ElixIRCd.Service

  require Logger

  import ElixIRCd.Utils.Nickserv, only: [send_notice: 2]
  import ElixIRCd.Utils.Protocol, only: [user_mask: 1]

  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.RegisteredNick
  alias ElixIRCd.Tables.User

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(user, ["SET", subcommand | rest_params]) do
    normalized_subcommand = String.upcase(subcommand)

    if user.identified_as do
      case normalized_subcommand do
        "HIDEMAIL" -> handle_hidemail(user, rest_params)
        _ -> unknown_subcommand_message(user, subcommand)
      end
    else
      send_notice(user, "You must identify to NickServ before using the SET command.")
      send_notice(user, "Use \x02/msg NickServ IDENTIFY <password>\x02 to identify.")
    end

    :ok
  end

  def handle(user, ["SET"]) do
    send_notice(user, "Insufficient parameters for \x02SET\x02.")
    send_notice(user, "Syntax: \x02SET <option> <parameters>\x02")
    send_available_settings(user)
    :ok
  end

  def handle(user, ["SET" | _rest_params]) do
    send_notice(user, "Insufficient parameters for \x02SET\x02.")
    send_notice(user, "Syntax: \x02SET <option> <parameters>\x02")
    :ok
  end

  @spec handle_hidemail(User.t(), [String.t()]) :: :ok
  defp handle_hidemail(user, [value | _rest_params]) do
    case String.upcase(value) do
      "ON" ->
        update_hidemail_setting(user, true)

      "OFF" ->
        update_hidemail_setting(user, false)

      _ ->
        send_notice(user, "Invalid parameter for \x02HIDEMAIL\x02.")
        send_notice(user, "Syntax: \x02SET HIDEMAIL {ON|OFF}\x02")
    end

    :ok
  end

  defp handle_hidemail(user, []) do
    send_notice(user, "Insufficient parameters for \x02HIDEMAIL\x02.")
    send_notice(user, "Syntax: \x02SET HIDEMAIL {ON|OFF}\x02")
    :ok
  end

  @spec update_hidemail_setting(User.t(), boolean()) :: :ok
  defp update_hidemail_setting(user, hide_email) do
    case RegisteredNicks.get_by_nickname(user.identified_as) do
      {:ok, registered_nick} ->
        updated_settings = RegisteredNick.Settings.update(registered_nick.settings, hide_email: hide_email)
        RegisteredNicks.update(registered_nick, %{settings: updated_settings})

        if hide_email do
          send_notice(user, "Your email address will now be hidden from \x02INFO\x02 displays.")
        else
          send_notice(user, "Your email address will now be shown in \x02INFO\x02 displays.")
        end

        Logger.info("User #{user_mask(user)} set HIDEMAIL to #{if hide_email, do: "ON", else: "OFF"}")

      {:error, reason} ->
        Logger.error("Error updating settings for #{user.identified_as}: #{inspect(reason)}")
        send_notice(user, "An error occurred while updating your settings.")
    end

    :ok
  end

  @spec unknown_subcommand_message(User.t(), String.t()) :: :ok
  defp unknown_subcommand_message(user, subcommand) do
    send_notice(user, "Unknown SET option: \x02#{subcommand}\x02")
    send_available_settings(user)
    :ok
  end

  @spec send_available_settings(User.t()) :: :ok
  defp send_available_settings(user) do
    send_notice(user, "Available SET options:")
    send_notice(user, "\x02HIDEMAIL\x02     - Hide your email address in INFO displays")
    :ok
  end
end
