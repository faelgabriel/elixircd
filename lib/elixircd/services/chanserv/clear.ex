defmodule ElixIRCd.Services.Chanserv.Clear do
  @moduledoc """
  This module defines the ChanServ CLEAR command.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.ChannelExcepts
  alias ElixIRCd.Repositories.ChannelInvexes
  alias ElixIRCd.Repositories.RegisteredChannelAccesses
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Services.Chanserv.Channel.Context, as: ChannelContext
  alias ElixIRCd.Services.Chanserv.Channel.Moderation
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Tables.ChannelExcept
  alias ElixIRCd.Tables.ChannelInvex
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Chanserv.Flags

  @command_name "CLEAR"

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, [@command_name | _]) do
    notify(user, "You must be identified with NickServ to use this command.")
  end

  def handle(user, [@command_name, channel_name, subcommand | _rest]) do
    case String.upcase(subcommand) do
      "BANS" -> clear_bans(user, channel_name)
      "FLAGS" -> clear_flags(user, channel_name)
      "USERS" -> clear_users(user, channel_name)
      unknown -> unknown_subcommand(user, unknown)
    end
  end

  def handle(user, [@command_name | _]) do
    notify(user, [
      "Insufficient parameters for \x02CLEAR\x02.",
      "Syntax: \x02CLEAR <channel> {BANS|FLAGS|USERS}\x02"
    ])
  end

  @spec clear_bans(User.t(), String.t()) :: :ok
  defp clear_bans(user, channel_name) do
    with {:ok, registered_channel} <- ChannelContext.get_registered_channel(channel_name),
         access_entries = ChannelContext.get_access_entries(registered_channel.name),
         :ok <- Flags.can_use_moderation(registered_channel, user.identified_as, access_entries),
         {:ok, channel, _user_channels, channel_users} <-
           ChannelContext.get_online_channel_state(registered_channel.name),
         entries <- ban_entries(channel),
         false <- entries == [] do
      Enum.each(entries, fn {mode, entry} ->
        delete_ban_entry(entry)

        %Message{command: "MODE", params: [channel.name, "-#{mode}", entry.mask]}
        |> Dispatcher.broadcast(:chanserv, channel_users)
      end)

      notify(
        user,
        "Cleared \x02#{length(entries)}\x02 ban #{pluralize_entries(length(entries))} from \x02#{channel.name}\x02."
      )
    else
      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :channel_not_in_use} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not currently in use.")

      {:error, :access_denied} ->
        notify(user, "Access denied for \x02#{channel_name}\x02.")

      true ->
        notify(user, "There are no ban entries to clear on \x02#{channel_name}\x02.")
    end
  end

  @spec clear_flags(User.t(), String.t()) :: :ok
  defp clear_flags(user, channel_name) do
    with {:ok, registered_channel} <- ChannelContext.get_registered_channel(channel_name),
         access_entries = ChannelContext.get_access_entries(registered_channel.name),
         :ok <- Flags.can_manage_flags(registered_channel, user.identified_as, access_entries),
         false <- access_entries == %{} do
      RegisteredChannelAccesses.delete_by_channel_name(registered_channel.name)

      notify(
        user,
        "Cleared \x02#{map_size(access_entries)}\x02 ChanServ flag #{pluralize_entries(map_size(access_entries))} from \x02#{registered_channel.name}\x02."
      )
    else
      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :access_denied} ->
        notify(user, "Access denied for \x02#{channel_name}\x02.")

      true ->
        notify(user, "There are no explicit ChanServ flags to clear on \x02#{channel_name}\x02.")
    end
  end

  @spec clear_users(User.t(), String.t()) :: :ok
  defp clear_users(user, channel_name) do
    with {:ok, registered_channel} <- ChannelContext.get_registered_channel(channel_name),
         access_entries = ChannelContext.get_access_entries(registered_channel.name),
         :ok <- Flags.can_use_moderation(registered_channel, user.identified_as, access_entries),
         {:ok, channel, _user_channels, channel_users} <-
           ChannelContext.get_online_channel_state(registered_channel.name),
         false <- channel_users == [],
         :ok <- Moderation.ensure_peace(registered_channel, user, channel_users, access_entries),
         kicked_count <- Moderation.kick_targets(channel, channel_users, "CLEAR USERS used by #{user.nick}") do
      notify(user, "Cleared \x02#{kicked_count}\x02 #{pluralize_users(kicked_count)} from \x02#{channel.name}\x02.")
    else
      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :channel_not_in_use} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not currently in use.")

      {:error, :access_denied} ->
        notify(user, "Access denied for \x02#{channel_name}\x02.")

      {:error, :peace_denied} ->
        notify(
          user,
          "Channel \x02#{channel_name}\x02 has \x02PEACE\x02 enabled; you cannot clear users while a protected target matches."
        )

      true ->
        notify(user, "There are no users to clear on \x02#{channel_name}\x02.")
    end
  end

  @spec unknown_subcommand(User.t(), String.t()) :: :ok
  defp unknown_subcommand(user, unknown) do
    notify(user, [
      "Unknown CLEAR subcommand: \x02#{unknown}\x02",
      "Syntax: \x02CLEAR <channel> {BANS|FLAGS|USERS}\x02"
    ])
  end

  @spec ban_entries(Channel.t()) :: [{String.t(), ChannelBan.t() | ChannelExcept.t() | ChannelInvex.t()}]
  defp ban_entries(channel) do
    Enum.concat([
      Enum.map(ChannelBans.get_by_channel_name_key(channel.name_key), &{"b", &1}),
      Enum.map(ChannelExcepts.get_by_channel_name_key(channel.name_key), &{"e", &1}),
      Enum.map(ChannelInvexes.get_by_channel_name_key(channel.name_key), &{"I", &1})
    ])
  end

  @spec delete_ban_entry(ChannelBan.t() | ChannelExcept.t() | ChannelInvex.t()) :: :ok
  defp delete_ban_entry(%ChannelBan{} = entry), do: ChannelBans.delete(entry)
  defp delete_ban_entry(%ChannelExcept{} = entry), do: ChannelExcepts.delete(entry)
  defp delete_ban_entry(%ChannelInvex{} = entry), do: ChannelInvexes.delete(entry)

  @spec pluralize_entries(non_neg_integer()) :: String.t()
  defp pluralize_entries(1), do: "entry"
  defp pluralize_entries(_count), do: "entries"

  @spec pluralize_users(non_neg_integer()) :: String.t()
  defp pluralize_users(1), do: "user"
  defp pluralize_users(_count), do: "users"
end
