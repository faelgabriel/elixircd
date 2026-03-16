defmodule ElixIRCd.Services.Chanserv.Kick do
  @moduledoc """
  This module defines the ChanServ KICK command.
  """

  @behaviour ElixIRCd.Service

  import ElixIRCd.Utils.Chanserv, only: [notify: 2]
  import ElixIRCd.Utils.Protocol, only: [match_user_mask?: 2, normalize_mask: 1]

  alias ElixIRCd.Repositories.UserChannels
  alias ElixIRCd.Repositories.Users
  alias ElixIRCd.Services.Chanserv.Channel.Context, as: ChannelContext
  alias ElixIRCd.Services.Chanserv.Channel.Moderation
  alias ElixIRCd.Tables.Channel
  alias ElixIRCd.Tables.User
  alias ElixIRCd.Utils.Chanserv.Flags

  @command_name "KICK"

  @impl true
  @spec handle(User.t(), [String.t()]) :: :ok
  def handle(%{identified_as: nil} = user, [@command_name | _]) do
    notify(user, "You must be identified with NickServ to use this command.")
  end

  def handle(user, [@command_name, channel_name, target | reason_parts]) do
    with {:ok, registered_channel} <- ChannelContext.get_registered_channel(channel_name),
         access_entries = ChannelContext.get_access_entries(registered_channel.name),
         :ok <- Flags.can_use_moderation(registered_channel, user.identified_as, access_entries),
         {:ok, channel, _user_channels, channel_users} <-
           ChannelContext.get_online_channel_state(registered_channel.name),
         {:ok, targets} <- resolve_targets(channel, channel_users, target),
         :ok <- Moderation.ensure_peace(registered_channel, user, targets, access_entries),
         kicked_count <- Moderation.kick_targets(channel, targets, kick_reason(user.nick, reason_parts)) do
      notify(user, "Kicked \x02#{kicked_count}\x02 #{pluralize(kicked_count)} from \x02#{channel.name}\x02.")
    else
      {:error, :registered_channel_not_found} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not registered.")

      {:error, :channel_not_in_use} ->
        notify(user, "Channel \x02#{channel_name}\x02 is not currently in use.")

      {:error, :access_denied} ->
        notify(user, "Access denied for \x02#{channel_name}\x02.")

      {:error, :target_not_on_channel} ->
        notify(user, "\x02#{target}\x02 is not on \x02#{channel_name}\x02.")

      {:error, :no_matching_targets} ->
        notify(user, "No matching users for \x02#{target}\x02 were found on \x02#{channel_name}\x02.")

      {:error, :peace_denied} ->
        notify(
          user,
          "Channel \x02#{channel_name}\x02 has \x02PEACE\x02 enabled; you cannot kick a matching protected target."
        )
    end
  end

  def handle(user, [@command_name | _]) do
    notify(user, [
      "Insufficient parameters for \x02KICK\x02.",
      "Syntax: \x02KICK <channel> <nickname|mask> [reason]\x02"
    ])
  end

  @spec resolve_targets(Channel.t(), [User.t()], String.t()) ::
          {:ok, [User.t()]} | {:error, :no_matching_targets | :target_not_on_channel}
  defp resolve_targets(channel, channel_users, target) do
    case Users.get_by_nick(target) do
      {:ok, target_user} ->
        case UserChannels.get_by_user_pid_and_channel_name(target_user.pid, channel.name) do
          {:ok, _user_channel} -> {:ok, [target_user]}
          {:error, :user_channel_not_found} -> {:error, :target_not_on_channel}
        end

      {:error, :user_not_found} ->
        mask = normalize_mask(target)
        targets = Enum.filter(channel_users, &match_user_mask?(&1, mask))

        if targets == [] do
          {:error, :no_matching_targets}
        else
          {:ok, targets}
        end
    end
  end

  @spec kick_reason(String.t(), [String.t()]) :: String.t()
  defp kick_reason(requester_nick, []), do: "Requested by #{requester_nick}"
  defp kick_reason(_requester_nick, reason_parts), do: Enum.join(reason_parts, " ")

  @spec pluralize(non_neg_integer()) :: String.t()
  defp pluralize(1), do: "user"
  defp pluralize(_count), do: "users"
end
