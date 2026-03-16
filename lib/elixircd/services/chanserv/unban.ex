defmodule ElixIRCd.Services.Chanserv.Unban do
  @moduledoc """
  This module defines the ChanServ UNBAN command.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]

  import ElixIRCd.Utils.Protocol, only: [match_user_mask?: 2, normalize_mask: 1]

  alias ElixIRCd.Message
  alias ElixIRCd.Repositories.ChannelBans
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Services.Chanserv.Channel.Context, as: ChannelContext
  alias ElixIRCd.Tables.ChannelBan
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Chanserv.Flags

  @command_name "UNBAN"

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, [@command_name | _]) do
    notify(user, "You must be identified with NickServ to use this command.")
  end

  def handle(user, [@command_name, channel_name]) do
    handle(user, [@command_name, channel_name, user.nick])
  end

  def handle(user, [@command_name, channel_name, target | _rest]) do
    with {:ok, registered_channel} <- ChannelContext.get_registered_channel(channel_name),
         access_entries = ChannelContext.get_access_entries(registered_channel.name),
         :ok <- Flags.can_use_moderation(registered_channel, user.identified_as, access_entries),
         {:ok, channel, _user_channels, channel_users} <-
           ChannelContext.get_online_channel_state(registered_channel.name),
         matching_bans <- matching_bans(channel.name_key, target),
         false <- matching_bans == [] do
      Enum.each(matching_bans, fn ban ->
        ChannelBans.delete(ban)

        %Message{command: "MODE", params: [channel.name, "-b", ban.mask]}
        |> Dispatcher.broadcast(:chanserv, channel_users)
      end)

      notify(
        user,
        "Removed \x02#{length(matching_bans)}\x02 ban #{pluralize(length(matching_bans))} from \x02#{channel.name}\x02."
      )
    else
      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :channel_not_in_use} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not currently in use.")

      {:error, :access_denied} ->
        notify(user, "Access denied for \x02#{channel_name}\x02.")

      true ->
        notify(user, "No matching bans were found on \x02#{channel_name}\x02.")
    end
  end

  def handle(user, [@command_name | _]) do
    notify(user, "Syntax: \x02UNBAN <channel> [nickname|mask]\x02")
  end

  @spec matching_bans(String.t(), String.t()) :: [ChannelBan.t()]
  defp matching_bans(channel_name_key, target) do
    channel_bans = ChannelBans.get_by_channel_name_key(channel_name_key)

    case Users.get_by_nick(target) do
      {:ok, target_user} ->
        Enum.filter(channel_bans, &match_user_mask?(target_user, &1.mask))

      {:error, :user_not_found} ->
        normalized_mask = normalize_mask(target)
        Enum.filter(channel_bans, &(&1.mask == normalized_mask))
    end
  end

  @spec pluralize(non_neg_integer()) :: String.t()
  defp pluralize(1), do: "entry"
  defp pluralize(_count), do: "entries"
end
