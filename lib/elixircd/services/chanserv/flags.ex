defmodule ElixIRCd.Services.Chanserv.Flags do
  @moduledoc """
  This module defines the ChanServ FLAGS command.

  FLAGS manages channel permissions using symbolic flag strings.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]

  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Chanserv.Flags, as: ChannelFlags

  @command_name "FLAGS"

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, [@command_name | _]) do
    notify(user, "You must be identified with NickServ to use this command.")
  end

  def handle(user, [@command_name, channel_name]) do
    with {:ok, channel} <- RegisteredChannels.get_by_name(channel_name),
         access_entries = get_access_entries(channel.name),
         :ok <- ChannelFlags.can_view_privileged_info(channel, user.identified_as, access_entries) do
      list_flags(user, channel, access_entries)
    else
      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :access_denied} ->
        notify(user, "Access denied for \x02#{channel_name}\x02.")
    end
  end

  def handle(user, [@command_name, channel_name, nickname]) do
    with {:ok, channel} <- RegisteredChannels.get_by_name(channel_name),
         access_entries = get_access_entries(channel.name),
         :ok <- ChannelFlags.can_view_privileged_info(channel, user.identified_as, access_entries),
         {:ok, %{account_name: account_name}} <- RegisteredNicks.get_by_nickname(nickname) do
      show_flags(user, channel, account_name, access_entries)
    else
      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :registered_nick_not_found} ->
        notify(user, "The nickname \x02#{nickname}\x02 is not registered.")

      {:error, :access_denied} ->
        notify(user, "Access denied for \x02#{channel_name}\x02.")
    end
  end

  def handle(user, [@command_name, channel_name, nickname, changes]) do
    with {:ok, channel} <- RegisteredChannels.get_by_name(channel_name),
         access_entries = get_access_entries(channel.name),
         :ok <- ChannelFlags.can_manage_flags(channel, user.identified_as, access_entries),
         {:ok, %{account_name: account_name}} <- RegisteredNicks.get_by_nickname(nickname),
         false <- ChannelFlags.founder?(channel, account_name),
         {:ok, updated_flags} <-
           ChannelFlags.apply_flag_changes(
             ChannelFlags.flags_for_account(channel, account_name, access_entries),
             String.upcase(changes)
           ) do
      persist_flags(channel.name, account_name, updated_flags)

      case updated_flags do
        "" ->
          notify(user, "All explicit flags for \x02#{account_name}\x02 on \x02#{channel.name}\x02 have been cleared.")

        _ ->
          notify(user, "Flags for \x02#{account_name}\x02 on \x02#{channel.name}\x02 are now \x02#{updated_flags}\x02.")
      end
    else
      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :registered_nick_not_found} ->
        notify(user, "The nickname \x02#{nickname}\x02 is not registered.")

      true ->
        notify(user, "The founder has implicit flags and cannot be changed with FLAGS.")

      {:error, :invalid_flags} ->
        supported_flags = ChannelFlags.supported_flags() |> Enum.join()
        notify(user, "Invalid flags. Supported flags are \x02#{supported_flags}\x02, and you may use + or - prefixes.")

      {:error, :access_denied} ->
        notify(user, "Access denied for \x02#{channel_name}\x02.")
    end
  end

  def handle(user, [@command_name | _]) do
    notify(user, [
      "Insufficient parameters for \x02FLAGS\x02.",
      "Syntax: \x02FLAGS <channel> [nickname [flags]]\x02"
    ])
  end

  @spec get_access_entries(String.t()) :: %{optional(String.t()) => String.t()}
  defp get_access_entries(channel_name) do
    channel_name
    |> RegisteredChannelAccesses.get_flags_map_by_channel_name()
    |> ChannelFlags.normalize_access_entries()
  end

  @spec persist_flags(String.t(), String.t(), String.t()) :: :ok
  defp persist_flags(channel_name, account_name, "") do
    RegisteredChannelAccesses.delete(channel_name, account_name)
  end

  defp persist_flags(channel_name, account_name, flags) do
    RegisteredChannelAccesses.create(%{
      channel_name: channel_name,
      account_name: account_name,
      flags: flags
    })

    :ok
  end

  @spec list_flags(User.t(), RegisteredChannel.t(), %{optional(String.t()) => String.t()}) :: :ok
  defp list_flags(user, channel, access_entries) do
    notify(user, "Flags for \x02#{channel.name}\x02:")
    notify(user, "Founder: \x02#{channel.founder}\x02 -> \x02#{ChannelFlags.founder_flags()}\x02 (implicit)")

    access_entries
    |> Enum.sort_by(fn {account_name, _flags} -> account_name end)
    |> Enum.with_index(1)
    |> Enum.each(fn {{account_name, flags}, index} ->
      notify(user, "#{index}. \x02#{account_name}\x02 -> \x02#{flags}\x02")
    end)

    notify(user, "End of flag list.")
  end

  @spec show_flags(User.t(), RegisteredChannel.t(), String.t(), %{optional(String.t()) => String.t()}) :: :ok
  defp show_flags(user, channel, account_name, access_entries) do
    flags = ChannelFlags.flags_for_account(channel, account_name, access_entries)

    if flags == "" do
      notify(user, "\x02#{account_name}\x02 has no explicit flags on \x02#{channel.name}\x02.")
    else
      suffix = if ChannelFlags.founder?(channel, account_name), do: " (implicit founder flags)", else: ""
      notify(user, "Flags for \x02#{account_name}\x02 on \x02#{channel.name}\x02: \x02#{flags}\x02#{suffix}")
    end
  end
end
