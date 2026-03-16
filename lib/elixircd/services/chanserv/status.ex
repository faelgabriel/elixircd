defmodule ElixIRCd.Services.Chanserv.Status do
  @moduledoc """
  This module defines the ChanServ STATUS command.

  STATUS reports the ChanServ access held by an account on a channel.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]

  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Chanserv.Flags

  @command_name "STATUS"

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, [@command_name]) do
    notify(user, [
      "Insufficient parameters for \x02STATUS\x02.",
      "Syntax: \x02STATUS <channel> [nickname]\x02"
    ])
  end

  def handle(user, [@command_name]) do
    notify(user, [
      "Insufficient parameters for \x02STATUS\x02.",
      "Syntax: \x02STATUS <channel> [nickname]\x02"
    ])
  end

  def handle(user, [@command_name, channel_name]) do
    if user.identified_as do
      show_status(user, channel_name, user.identified_as)
    else
      notify(user, "You must be identified with NickServ or specify a nickname to use this command.")
    end
  end

  def handle(user, [@command_name, channel_name, nickname]) do
    case RegisteredNicks.get_by_nickname(nickname) do
      {:ok, registered_nick} ->
        show_status(user, channel_name, registered_nick.account_name)

      {:error, :registered_nick_not_found} ->
        notify(user, "The nickname \x02#{nickname}\x02 is not registered.")
    end
  end

  def handle(user, [@command_name | _]) do
    notify(user, "Syntax: \x02STATUS <channel> [nickname]\x02")
  end

  @spec show_status(User.t(), String.t(), String.t()) :: :ok
  defp show_status(user, channel_name, account_name) do
    case RegisteredChannels.get_by_name(channel_name) do
      {:ok, channel} ->
        access_entries = RegisteredChannelAccesses.get_flags_map_by_channel_name(channel.name)
        flags = Flags.flags_for_account(channel, account_name, access_entries)

        if flags == "" do
          notify(user, "\x02#{account_name}\x02 has no ChanServ access on \x02#{channel.name}\x02.")
        else
          notify(user, format_status_message(channel.name, account_name, flags, Flags.founder?(channel, account_name)))
        end

      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")
    end
  end

  @spec format_status_message(String.t(), String.t(), String.t(), boolean()) :: String.t()
  defp format_status_message(channel_name, account_name, flags, founder?) do
    suffix = if founder?, do: ", founder", else: ""

    "Status for \x02#{account_name}\x02 on \x02#{channel_name}\x02: level #{Flags.access_level_text(flags)} (flags \x02#{flags}\x02#{suffix})"
  end
end
