defmodule ElixIRCd.Services.Chanserv.Access do
  @moduledoc """
  This module defines the ChanServ ACCESS command.

  ACCESS manages a channel's compatibility access list using numeric levels.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]

  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Repositories.RegisteredChannels
  alias ElixIRCd.Repositories.RegisteredNicks
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Chanserv.Flags

  @command_name "ACCESS"

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, [@command_name | _]) do
    notify(user, "You must be identified with NickServ to use this command.")
  end

  def handle(user, [@command_name, channel_name, subcommand | args]) do
    normalized_subcommand = String.upcase(subcommand)

    case get_channel(channel_name) do
      {:ok, channel} ->
        access_entries = get_access_entries(channel.name)
        dispatch_subcommand(user, channel, access_entries, normalized_subcommand, args)

      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")
    end
  end

  def handle(user, [@command_name | _]) do
    notify(user, [
      "Insufficient parameters for \x02ACCESS\x02.",
      "Syntax: \x02ACCESS <channel> {ADD|DEL|LIST|CLEAR} [nickname] [level]\x02"
    ])
  end

  @spec get_channel(String.t()) :: {:ok, RegisteredChannel.t()} | {:error, :registered_channel_not_found}
  defp get_channel(channel_name), do: RegisteredChannels.get_by_name(channel_name)

  @spec get_access_entries(String.t()) :: %{optional(String.t()) => String.t()}
  defp get_access_entries(channel_name) do
    channel_name
    |> RegisteredChannelAccesses.get_flags_map_by_channel_name()
    |> Flags.normalize_access_entries()
  end

  @spec dispatch_subcommand(User.t(), RegisteredChannel.t(), %{optional(String.t()) => String.t()}, String.t(), [
          String.t()
        ]) :: :ok
  defp dispatch_subcommand(user, channel, access_entries, "LIST", args) do
    case Flags.can_view_privileged_info(channel, user.identified_as, access_entries) do
      :ok -> handle_subcommand(user, channel, access_entries, "LIST", args)
      {:error, :access_denied} -> notify(user, "Access denied for \x02#{channel.name}\x02.")
    end
  end

  defp dispatch_subcommand(user, channel, access_entries, subcommand, args)
       when subcommand in ["ADD", "DEL", "CLEAR"] do
    case Flags.can_manage_access(channel, user.identified_as, access_entries) do
      :ok -> handle_subcommand(user, channel, access_entries, subcommand, args)
      {:error, :access_denied} -> notify(user, "Access denied for \x02#{channel.name}\x02.")
    end
  end

  defp dispatch_subcommand(user, channel, access_entries, subcommand, args) do
    handle_subcommand(user, channel, access_entries, subcommand, args)
  end

  @spec handle_subcommand(User.t(), RegisteredChannel.t(), %{optional(String.t()) => String.t()}, String.t(), [
          String.t()
        ]) :: :ok
  defp handle_subcommand(user, channel, access_entries, "LIST", _args) do
    entries = Enum.sort_by(access_entries, fn {account_name, _flags} -> account_name end)

    if Enum.empty?(entries) do
      notify(user, "The access list for \x02#{channel.name}\x02 is empty.")
    else
      notify(user, "Access list for \x02#{channel.name}\x02:")
      notify(user, "Founder: \x02#{channel.founder}\x02 (level 5, flags \x02#{Flags.founder_flags()}\x02)")

      entries
      |> Enum.with_index(1)
      |> Enum.each(fn {{account_name, flags}, index} ->
        level_text = Flags.access_level_text(flags)
        notify(user, "#{index}. \x02#{account_name}\x02 level #{level_text} (flags \x02#{flags}\x02)")
      end)

      notify(user, "End of access list.")
    end
  end

  defp handle_subcommand(user, channel, access_entries, "ADD", [nickname, level_text]) do
    with {:ok, %{account_name: account_name}} <- RegisteredNicks.get_by_nickname(nickname),
         false <- Flags.founder?(channel, account_name),
         {:ok, flags} <- parse_level(level_text) do
      current_flags = Flags.flags_for_account(channel, account_name, access_entries)

      if current_flags == flags do
        notify(
          user,
          "\x02#{account_name}\x02 already has access level \x02#{level_text}\x02 on \x02#{channel.name}\x02."
        )
      else
        RegisteredChannelAccesses.create(%{
          channel_name: channel.name,
          account_name: account_name,
          flags: flags
        })

        notify(
          user,
          "Access for \x02#{account_name}\x02 on \x02#{channel.name}\x02 is now level \x02#{level_text}\x02 (flags \x02#{flags}\x02)."
        )
      end
    else
      {:error, :registered_nick_not_found} ->
        notify(user, "The nickname \x02#{nickname}\x02 is not registered.")

      true ->
        notify(user, "The founder \x02#{channel.founder}\x02 has implicit access and cannot be changed with ACCESS.")

      {:error, :invalid_level} ->
        notify(user, "Invalid access level. Supported levels are \x021\x02 through \x025\x02.")
    end
  end

  defp handle_subcommand(user, _channel, _access_entries, "ADD", _args) do
    notify(user, "Syntax: \x02ACCESS <channel> ADD <nickname> <level>\x02")
  end

  defp handle_subcommand(user, channel, access_entries, "DEL", [nickname]) do
    with {:ok, %{account_name: account_name}} <- RegisteredNicks.get_by_nickname(nickname),
         false <- Flags.founder?(channel, account_name) do
      if Map.has_key?(access_entries, account_name) do
        RegisteredChannelAccesses.delete(channel.name, account_name)
        notify(user, "Removed \x02#{account_name}\x02 from the access list for \x02#{channel.name}\x02.")
      else
        notify(user, "\x02#{account_name}\x02 is not in the access list for \x02#{channel.name}\x02.")
      end
    else
      {:error, :registered_nick_not_found} ->
        notify(user, "The nickname \x02#{nickname}\x02 is not registered.")

      true ->
        notify(user, "The founder \x02#{channel.founder}\x02 has implicit access and cannot be changed with ACCESS.")
    end
  end

  defp handle_subcommand(user, _channel, _access_entries, "DEL", _args) do
    notify(user, "Syntax: \x02ACCESS <channel> DEL <nickname>\x02")
  end

  defp handle_subcommand(user, channel, access_entries, "CLEAR", _args) do
    count = map_size(access_entries)

    if count == 0 do
      notify(user, "The access list for \x02#{channel.name}\x02 is already empty.")
    else
      RegisteredChannelAccesses.delete_by_channel_name(channel.name)
      notify(user, "Cleared \x02#{count}\x02 access #{pluralize_entries(count)} for \x02#{channel.name}\x02.")
    end
  end

  defp handle_subcommand(user, _channel, _access_entries, subcommand, _args) do
    notify(user, [
      "Unknown ACCESS subcommand: \x02#{subcommand}\x02",
      "Syntax: \x02ACCESS <channel> {ADD|DEL|LIST|CLEAR} [nickname] [level]\x02"
    ])
  end

  @spec parse_level(String.t()) :: {:ok, String.t()} | {:error, :invalid_level}
  defp parse_level(level_text) do
    case Integer.parse(level_text) do
      {level, ""} ->
        case Flags.access_level_to_flags(level) do
          {:ok, flags} -> {:ok, flags}
          :error -> {:error, :invalid_level}
        end

      _ ->
        {:error, :invalid_level}
    end
  end

  @spec pluralize_entries(non_neg_integer()) :: String.t()
  defp pluralize_entries(1), do: "entry"
  defp pluralize_entries(_count), do: "entries"
end
