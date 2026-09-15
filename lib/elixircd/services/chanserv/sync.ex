defmodule ElixIRCd.Services.Chanserv.Sync do
  @moduledoc """
  This module defines the ChanServ SYNC command.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]

  alias ElixIRCd.Message
  alias ElixIRCd.ModeRegistry
  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Server.Dispatcher
  alias ElixIRCd.Services.Chanserv.Channel.Context, as: ChannelContext
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.RegisteredChannel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Tables.UserChannel
  alias ElixIRCd.Utils.Chanserv.Flags

  @command_name "SYNC"
  @managed_modes [:o, :v]

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, [@command_name | _]) do
    notify(user, "You must be identified with NickServ to use this command.")
  end

  def handle(user, [@command_name, channel_name]) do
    with {:ok, registered_channel} <- ChannelContext.get_registered_channel(channel_name),
         access_entries = ChannelContext.get_access_entries(registered_channel.name),
         :ok <- Flags.can_use_moderation(registered_channel, user.identified_as, access_entries),
         {:ok, channel, user_channels, channel_users} <-
           ChannelContext.get_online_channel_state(registered_channel.name) do
      synced_count = sync_users(channel, registered_channel, access_entries, user_channels, channel_users)

      if synced_count == 0 do
        notify(user, "Channel \x02#{channel.name}\x02 is already synchronized.")
      else
        notify(user, "Synchronized \x02#{synced_count}\x02 #{pluralize(synced_count)} on \x02#{channel.name}\x02.")
      end
    else
      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :channel_not_in_use} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not currently in use.")

      {:error, :access_denied} ->
        notify(user, "Access denied for \x02#{channel_name}\x02.")
    end
  end

  def handle(user, [@command_name | _]) do
    notify(user, "Syntax: \x02SYNC <channel>\x02")
  end

  @spec sync_users(
          Channel.t(),
          RegisteredChannel.t(),
          %{optional(String.t()) => String.t()},
          [UserChannel.t()],
          [User.t()]
        ) :: non_neg_integer()
  defp sync_users(channel, registered_channel, access_entries, user_channels, channel_users) do
    users_by_pid = Map.new(channel_users, fn channel_user -> {channel_user.pid, channel_user} end)

    context = %{
      channel: channel,
      registered_channel: registered_channel,
      access_entries: access_entries,
      channel_users: channel_users
    }

    Enum.reduce(user_channels, 0, fn user_channel, synced_count ->
      # The user may have quit after the snapshot; skip instead of crashing.
      case Map.fetch(users_by_pid, user_channel.user_pid) do
        {:ok, user} -> sync_user_channel(context, user_channel, user, synced_count)
        :error -> synced_count
      end
    end)
  end

  @spec sync_user_channel(map(), UserChannel.t(), User.t(), non_neg_integer()) :: non_neg_integer()
  defp sync_user_channel(context, user_channel, user, synced_count) do
    %{registered_channel: registered_channel, access_entries: access_entries} = context
    desired_modes = Flags.desired_channel_modes(registered_channel, user.identified_as, access_entries)
    current_modes = Enum.filter(user_channel.modes, &(&1 in @managed_modes))

    if Enum.sort(current_modes) == Enum.sort(desired_modes) do
      synced_count
    else
      updated_modes =
        user_channel.modes
        |> Enum.reject(&(&1 in @managed_modes))
        |> Kernel.++(desired_modes)

      UserChannels.update(user_channel, %{modes: updated_modes})
      broadcast_mode_diff(context.channel, context.channel_users, user, current_modes, desired_modes)
      synced_count + 1
    end
  end

  @spec broadcast_mode_diff(
          Channel.t(),
          [User.t()],
          User.t(),
          [ModeRegistry.membership_mode()],
          [ModeRegistry.membership_mode()]
        ) :: :ok
  defp broadcast_mode_diff(channel, channel_users, user, current_modes, desired_modes) do
    removed_modes = current_modes -- desired_modes
    added_modes = desired_modes -- current_modes

    Enum.each(removed_modes, fn mode ->
      %Message{command: "MODE", params: [channel.name, "-" <> ModeRegistry.encode!(:membership, mode), user.nick]}
      |> Dispatcher.broadcast(:chanserv, channel_users)
    end)

    Enum.each(added_modes, fn mode ->
      %Message{command: "MODE", params: [channel.name, "+" <> ModeRegistry.encode!(:membership, mode), user.nick]}
      |> Dispatcher.broadcast(:chanserv, channel_users)
    end)

    :ok
  end

  @spec pluralize(non_neg_integer()) :: String.t()
  defp pluralize(1), do: "user"
  defp pluralize(_count), do: "users"
end
