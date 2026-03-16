defmodule ElixIRCd.Services.Chanserv.Alist do
  @moduledoc """
  This module defines the ChanServ ALIST command.

  ALIST shows the channels an account can access through ChanServ.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]

  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Chanserv.Flags

  @command_name "ALIST"

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, [@command_name]) do
    notify(user, "You must be identified with NickServ to use this command.")
  end

  def handle(%{identified_as: nil} = user, [@command_name, nickname]) do
    show_account_channels(user, nickname)
  end

  def handle(user, [@command_name]) do
    list_account_channels(user, user.identified_as)
  end

  def handle(user, [@command_name, nickname]) do
    show_account_channels(user, nickname)
  end

  def handle(user, [@command_name | _]) do
    notify(user, "Syntax: \x02ALIST [nickname]\x02")
  end

  @spec show_account_channels(User.t(), String.t()) :: :ok
  defp show_account_channels(user, nickname) do
    case RegisteredNicks.get_by_nickname(nickname) do
      {:ok, registered_nick} ->
        list_account_channels(user, registered_nick.account_name)

      {:error, :registered_nick_not_found} ->
        notify(user, "The nickname \x02#{nickname}\x02 is not registered.")
    end
  end

  @spec list_account_channels(User.t(), String.t()) :: :ok
  defp list_account_channels(user, account_name) do
    entries = build_entries(account_name)

    if Enum.empty?(entries) do
      notify(user, "No ChanServ access entries were found for \x02#{account_name}\x02.")
    else
      notify(user, "ChanServ access list for \x02#{account_name}\x02:")

      entries
      |> Enum.with_index(1)
      |> Enum.each(fn {{channel_name, flags, founder?}, index} ->
        notify(user, format_alist_entry(index, channel_name, flags, founder?))
      end)

      notify(user, "End of ALIST.")
    end
  end

  @spec build_entries(String.t()) :: [{String.t(), String.t(), boolean()}]
  defp build_entries(account_name) do
    founder_entries =
      RegisteredChannels.get_by_founder(account_name)
      |> Enum.map(fn channel -> {channel.name, Flags.founder_flags(), true} end)

    explicit_entries =
      RegisteredChannelAccesses.get_by_account_name(account_name)
      |> Enum.map(fn entry -> {entry.channel_name_key, entry.flags, false} end)

    (founder_entries ++ explicit_entries)
    |> Enum.uniq_by(fn {channel_name, _flags, _founder?} -> channel_name end)
    |> Enum.sort_by(fn {channel_name, _flags, founder?} -> {not founder?, channel_name} end)
  end

  @spec format_alist_entry(pos_integer(), String.t(), String.t(), boolean()) :: String.t()
  defp format_alist_entry(index, channel_name, flags, founder?) do
    suffix = if founder?, do: ", founder", else: ""
    "#{index}. \x02#{channel_name}\x02 level #{Flags.access_level_text(flags)} (flags \x02#{flags}\x02#{suffix})"
  end
end
