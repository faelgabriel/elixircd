defmodule ElixIRCd.Services.Nickserv.Set do
  @moduledoc """
  Module for the NickServ SET command.
  """

  @behaviour ElixIRCd.Service

  require Logger

  import ElixIRCd.Utils.Nickserv, only: [notify: 2]

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
      notify(user, [
        "You must identify to NickServ before using the SET command.",
        "Use \x02/msg NickServ IDENTIFY <password>\x02 to identify."
      ])
    end
  end

  def handle(user, ["SET"]) do
    notify(user, [
      "Insufficient parameters for \x02SET\x02.",
      "Syntax: \x02SET <option> <parameters>\x02"
    ])

    send_available_settings(user)
  end

  @spec handle_hidemail(User.t(), [String.t()]) :: :ok
  defp handle_hidemail(user, [value | _rest_params]) do
    case String.upcase(value) do
      "ON" ->
        update_hidemail_setting(user, true)

      "OFF" ->
        update_hidemail_setting(user, false)

      _ ->
        notify(user, [
          "Invalid parameter for \x02HIDEMAIL\x02.",
          "Syntax: \x02SET HIDEMAIL {ON|OFF}\x02"
        ])
    end
  end

  defp handle_hidemail(user, []) do
    notify(user, [
      "Insufficient parameters for \x02HIDEMAIL\x02.",
      "Syntax: \x02SET HIDEMAIL {ON|OFF}\x02"
    ])
  end

  @spec update_hidemail_setting(User.t(), boolean()) :: :ok
  defp update_hidemail_setting(user, hide_email) do
    case RegisteredNicks.get_by_nickname(user.identified_as) do
      {:ok, registered_nick} ->
        updated_settings = RegisteredNick.Settings.update(registered_nick.settings, %{hide_email: hide_email})

        RegisteredNicks.update(registered_nick, %{settings: updated_settings})

        if hide_email do
          notify(user, "Your email address will now be hidden from \x02INFO\x02 displays.")
        else
          notify(user, "Your email address will now be shown in \x02INFO\x02 displays.")
        end

      {:error, error_reason} ->
        Logger.error("Error updating settings for #{user.identified_as}: #{inspect(error_reason)}")
        notify(user, "An error occurred while updating your settings.")
    end
  end

  @spec unknown_subcommand_message(User.t(), String.t()) :: :ok
  defp unknown_subcommand_message(user, subcommand) do
    notify(user, "Unknown SET option: \x02#{subcommand}\x02")
    send_available_settings(user)
  end

  @spec send_available_settings(User.t()) :: :ok
  defp send_available_settings(user) do
    notify(user, [
      "Available SET options:",
      "\x02HIDEMAIL\x02     - Hide your email address in INFO displays"
    ])
  end
end
